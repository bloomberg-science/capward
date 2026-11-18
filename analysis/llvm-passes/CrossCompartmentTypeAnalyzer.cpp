// Copyright 2026 Bloomberg Finance L.P.
// Distributed under the terms of the MIT license.

//===- CrossCompartmentTypeAnalyzer.cpp - Cross-compartment type sharing ===//
//
// Part of the CHERI static analysis project.
//
// This pass analyzes a single LLVM module (representing one library or the
// main program) and emits a JSON "type usage manifest" describing:
//   - All identified struct types with field layouts
//   - Which struct fields each defined function accesses
//   - External function calls and the struct types flowing through them
//   - Type flow summary: types received vs types passed out
//
// Designed for LLVM 15+ (opaque pointers, new pass manager only).
// Struct type information is extracted from GEP source element types and
// debug info. Debug info is required for field-0 detection (accesses at
// offset 0 that have no GEP) and for human-readable field names.
//
//===----------------------------------------------------------------------===//

#include "llvm/IR/Module.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/DebugInfo.h"
#include "llvm/IR/DebugInfoMetadata.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/BinaryFormat/Dwarf.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/PassManager.h"
#include "llvm/IR/DataLayout.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Passes/PassPlugin.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"

#include <map>
#include <set>
#include <string>
#include <sstream>
#include <vector>

using namespace llvm;

#define DEBUG_TYPE "cross-compartment-type-analyzer"

// ============================================================================
// JSON output helpers
// ============================================================================

static std::string escapeJSON(const std::string &S) {
  std::string Result;
  Result.reserve(S.size() + 8);
  for (char C : S) {
    switch (C) {
    case '"':  Result += "\\\""; break;
    case '\\': Result += "\\\\"; break;
    case '\n': Result += "\\n"; break;
    case '\r': Result += "\\r"; break;
    case '\t': Result += "\\t"; break;
    default:   Result += C; break;
    }
  }
  return Result;
}

// Simple JSON emitter using raw_ostream — avoids pulling in JSON library deps.
class JSONEmitter {
  raw_ostream &OS;
  unsigned Indent = 0;
  bool NeedComma = false;

  void indent() {
    for (unsigned i = 0; i < Indent; ++i)
      OS << "  ";
  }
  void comma() {
    if (NeedComma)
      OS << ",";
    OS << "\n";
  }

public:
  JSONEmitter(raw_ostream &OS) : OS(OS) {}

  void objectBegin(const std::string &Key = "") {
    comma();
    indent();
    if (!Key.empty())
      OS << "\"" << escapeJSON(Key) << "\": ";
    OS << "{";
    Indent++;
    NeedComma = false;
  }
  void objectEnd() {
    Indent--;
    OS << "\n";
    indent();
    OS << "}";
    NeedComma = true;
  }
  void arrayBegin(const std::string &Key) {
    comma();
    indent();
    OS << "\"" << escapeJSON(Key) << "\": [";
    Indent++;
    NeedComma = false;
  }
  void arrayEnd() {
    Indent--;
    OS << "\n";
    indent();
    OS << "]";
    NeedComma = true;
  }
  void stringField(const std::string &Key, const std::string &Val) {
    comma();
    indent();
    OS << "\"" << escapeJSON(Key) << "\": \"" << escapeJSON(Val) << "\"";
    NeedComma = true;
  }
  void intField(const std::string &Key, int64_t Val) {
    comma();
    indent();
    OS << "\"" << escapeJSON(Key) << "\": " << Val;
    NeedComma = true;
  }
  void boolField(const std::string &Key, bool Val) {
    comma();
    indent();
    OS << "\"" << escapeJSON(Key) << "\": " << (Val ? "true" : "false");
    NeedComma = true;
  }
  void nullField(const std::string &Key) {
    comma();
    indent();
    OS << "\"" << escapeJSON(Key) << "\": null";
    NeedComma = true;
  }
  void stringValue(const std::string &Val) {
    comma();
    indent();
    OS << "\"" << escapeJSON(Val) << "\"";
    NeedComma = true;
  }
  void intValue(int64_t Val) {
    comma();
    indent();
    OS << Val;
    NeedComma = true;
  }
  void nullValue() {
    comma();
    indent();
    OS << "null";
    NeedComma = true;
  }
};

// ============================================================================
// Helpers
// ============================================================================

static std::string getStructName(StructType *ST) {
  if (ST->hasName())
    return ST->getName().str();
  return "<anonymous-struct>";
}

static std::string typeToString(Type *T) {
  std::string Str;
  raw_string_ostream OS(Str);
  T->print(OS);
  return Str;
}

/// Get the struct type from a GEP's source element type.
static StructType *getGEPStructType(GetElementPtrInst *GEP) {
  Type *SrcTy = GEP->getSourceElementType();
  if (auto *ST = dyn_cast<StructType>(SrcTy))
    return ST;
  return nullptr;
}

// ============================================================================
// Debug info type resolution — fallback for opaque pointers without GEPs
// ============================================================================

/// Unwrap a DIType through pointer/typedef/const/volatile/restrict layers
/// to find the underlying DICompositeType (struct/union).
static DICompositeType *unwrapDIType(DIType *DT) {
  if (!DT)
    return nullptr;
  // Limit depth to avoid infinite loops on malformed metadata
  for (unsigned Depth = 0; Depth < 16; ++Depth) {
    if (auto *CT = dyn_cast<DICompositeType>(DT))
      return CT;
    if (auto *DDT = dyn_cast<DIDerivedType>(DT)) {
      unsigned Tag = DDT->getTag();
      if (Tag == dwarf::DW_TAG_pointer_type ||
          Tag == dwarf::DW_TAG_typedef ||
          Tag == dwarf::DW_TAG_const_type ||
          Tag == dwarf::DW_TAG_volatile_type ||
          Tag == dwarf::DW_TAG_restrict_type ||
          Tag == dwarf::DW_TAG_atomic_type) {
        DT = dyn_cast_or_null<DIType>(DDT->getBaseType());
        if (!DT)
          return nullptr;
        continue;
      }
    }
    break;
  }
  return nullptr;
}

/// Given a DIType that may be a pointer-to-struct, return the LLVM-style
/// struct name (e.g., "struct.ssl_ctx_st") or empty string.
static std::string getStructNameFromDIType(DIType *DT) {
  DICompositeType *CT = unwrapDIType(DT);
  if (!CT)
    return "";
  if (CT->getTag() != dwarf::DW_TAG_structure_type &&
      CT->getTag() != dwarf::DW_TAG_union_type)
    return "";
  StringRef Name = CT->getName();
  if (Name.empty())
    return "";
  return ("struct." + Name).str();
}

/// Unwrap qualifiers (typedef, const, volatile, restrict, atomic) from a DIType,
/// but do NOT strip pointer layers. Returns the underlying DIType after removing
/// qualifiers, or null.
static DIType *unwrapQualifiers(DIType *DT) {
  if (!DT)
    return nullptr;
  for (unsigned Depth = 0; Depth < 16; ++Depth) {
    auto *DDT = dyn_cast<DIDerivedType>(DT);
    if (!DDT)
      return DT;
    unsigned Tag = DDT->getTag();
    if (Tag == dwarf::DW_TAG_typedef ||
        Tag == dwarf::DW_TAG_const_type ||
        Tag == dwarf::DW_TAG_volatile_type ||
        Tag == dwarf::DW_TAG_restrict_type ||
        Tag == dwarf::DW_TAG_atomic_type) {
      DT = dyn_cast_or_null<DIType>(DDT->getBaseType());
      if (!DT)
        return nullptr;
      continue;
    }
    return DT; // not a qualifier — stop
  }
  return DT;
}

/// Check if a DIType represents exactly `pointer_to_struct` (one pointer
/// indirection to a struct/union). Returns the struct name as "struct.foo"
/// if so, or empty string otherwise. This is stricter than getStructNameFromDIType
/// which goes through multiple pointer levels.
static std::string getDirectPointeeStructName(DIType *DT) {
  // Strip qualifiers first (const struct foo* -> pointer to struct foo)
  DT = unwrapQualifiers(DT);
  if (!DT)
    return "";

  // Must be a pointer type
  auto *PtrDT = dyn_cast<DIDerivedType>(DT);
  if (!PtrDT || PtrDT->getTag() != dwarf::DW_TAG_pointer_type)
    return "";

  // Get what the pointer points to, stripping qualifiers
  DIType *PointeeDT =
      unwrapQualifiers(dyn_cast_or_null<DIType>(PtrDT->getBaseType()));
  if (!PointeeDT)
    return "";

  // Must be a composite (struct/union) directly — not another pointer
  auto *CT = dyn_cast<DICompositeType>(PointeeDT);
  if (!CT)
    return "";
  if (CT->getTag() != dwarf::DW_TAG_structure_type &&
      CT->getTag() != dwarf::DW_TAG_union_type)
    return "";

  StringRef Name = CT->getName();
  if (Name.empty())
    return "";
  return ("struct." + Name).str();
}

/// Resolve a Value to struct type name(s) using debug info.
/// Checks llvm.dbg.declare/value intrinsics and DbgVariableRecords
/// that reference the value or the alloca it was loaded from.
static void resolveStructTypesFromDebugInfo(
    Value *V, std::set<std::string> &TypeNames) {

  // Helper: extract struct name from a DbgVariable's type
  auto extractFromDbgVar = [&](DILocalVariable *Var) {
    if (!Var)
      return;
    std::string Name = getStructNameFromDIType(Var->getType());
    if (!Name.empty())
      TypeNames.insert(Name);
  };

  // Check debug intrinsics that reference V directly
  SmallVector<DbgVariableIntrinsic *, 4> DbgIntrinsics;
  findDbgUsers(DbgIntrinsics, V);
  for (auto *DVI : DbgIntrinsics)
    extractFromDbgVar(DVI->getVariable());

  // If V is a LoadInst, also check the alloca it loads from
  if (auto *LI = dyn_cast<LoadInst>(V)) {
    Value *Addr = LI->getPointerOperand();
    // Strip bitcasts/GEPs to find the alloca
    Value *Base = Addr->stripPointerCasts();

    SmallVector<DbgVariableIntrinsic *, 4> AddrDbgIntrinsics;
    findDbgUsers(AddrDbgIntrinsics, Base);
    for (auto *DVI : AddrDbgIntrinsics)
      extractFromDbgVar(DVI->getVariable());
  }
}

/// Get struct type names for a function's parameters from its DISubprogram.
/// Returns a map: param_index -> struct type name.
static void getParamTypesFromDebugInfo(
    Function &F,
    std::map<unsigned, std::string> &ParamDbgTypes) {

  DISubprogram *SP = F.getSubprogram();
  if (!SP)
    return;
  DISubroutineType *SRT = SP->getType();
  if (!SRT)
    return;

  auto TypeArray = SRT->getTypeArray();
  if (TypeArray.size() < 2)
    return; // element 0 is return type, 1+ are params

  // Element 0 is return type, elements 1..N are parameters
  for (unsigned i = 1; i < TypeArray.size(); ++i) {
    DIType *ParamDIType = TypeArray[i];
    if (!ParamDIType)
      continue;
    std::string Name = getStructNameFromDIType(ParamDIType);
    if (!Name.empty())
      ParamDbgTypes[i - 1] = Name; // map to 0-based param index
  }
}

/// Get the struct type name for a function's return type from its DISubprogram.
static std::string getReturnTypeFromDebugInfo(Function &F) {
  DISubprogram *SP = F.getSubprogram();
  if (!SP)
    return "";
  DISubroutineType *SRT = SP->getType();
  if (!SRT)
    return "";
  auto TypeArray = SRT->getTypeArray();
  if (TypeArray.size() < 1)
    return "";
  // Element 0 is the return type
  DIType *RetDIType = TypeArray[0];
  return getStructNameFromDIType(RetDIType);
}

/// Analyze the return type of a defined function by examining its body.
///
/// Unlike getReturnTypeFromDebugInfo (which reads the DISubprogram signature),
/// this traces actual return values through the function body to determine
/// what struct type is being returned.  This is critical for void*-returning
/// functions like SSL_CTX_get_ex_data: the signature says void*, but the
/// body may reveal the actual type (or confirm it's truly opaque).
///
/// The analysis uses a multi-stage approach:
///   Stage 1: DISubprogram return type (from the C function signature)
///   Stage 2: Body analysis — trace each ReturnInst's value backward
///
/// Returns the struct type name (e.g. "struct.ssl_ctx_st") or empty string
/// if the function doesn't return a struct pointer.
static std::string analyzeReturnType(Function &F) {
  // Must return a pointer to be relevant
  if (!F.getReturnType()->isPointerTy())
    return "";

  // Stage 1: DISubprogram return type (from C function signature)
  std::string sigRetType = getReturnTypeFromDebugInfo(F);

  // Stage 2: Body analysis — trace return values
  std::set<std::string> bodyRetTypes;

  for (auto &BB : F) {
    auto *RI = dyn_cast<ReturnInst>(BB.getTerminator());
    if (!RI)
      continue;
    Value *RetVal = RI->getReturnValue();
    if (!RetVal || !RetVal->getType()->isPointerTy())
      continue;
    if (isa<ConstantPointerNull>(RetVal))
      continue;

    // Try multiple resolution strategies for this return value

    // 2a: Debug info on the return value itself (dbg.value/dbg.declare)
    {
      std::set<std::string> DbgTypes;
      resolveStructTypesFromDebugInfo(RetVal, DbgTypes);
      bodyRetTypes.insert(DbgTypes.begin(), DbgTypes.end());
    }

    // 2b: If return value is a LoadInst, check the alloca's debug info
    if (auto *LI = dyn_cast<LoadInst>(RetVal)) {
      Value *Addr = LI->getPointerOperand()->stripPointerCasts();
      std::set<std::string> DbgTypes;
      resolveStructTypesFromDebugInfo(Addr, DbgTypes);
      // Also check debug intrinsics on the alloca directly
      SmallVector<DbgVariableIntrinsic *, 4> DbgIntrinsics;
      findDbgUsers(DbgIntrinsics, Addr);
      for (auto *DVI : DbgIntrinsics) {
        DILocalVariable *Var = DVI->getVariable();
        if (!Var) continue;
        std::string Name = getStructNameFromDIType(Var->getType());
        if (!Name.empty())
          DbgTypes.insert(Name);
      }
      bodyRetTypes.insert(DbgTypes.begin(), DbgTypes.end());
    }

    // 2c: If return value comes from a CallInst, use callee's return type
    if (auto *CI = dyn_cast<CallInst>(RetVal)) {
      Function *Callee = CI->getCalledFunction();
      if (Callee) {
        std::string CalleeRet = getReturnTypeFromDebugInfo(*Callee);
        if (!CalleeRet.empty())
          bodyRetTypes.insert(CalleeRet);
      }
    }

    // 2d: If return value is stored through an alloca, trace the store
    // This handles: retval = local_var; ... return retval;
    // where local_var was assigned from a typed expression
    if (auto *LI = dyn_cast<LoadInst>(RetVal)) {
      Value *Addr = LI->getPointerOperand()->stripPointerCasts();
      for (User *U : Addr->users()) {
        auto *SI = dyn_cast<StoreInst>(U);
        if (!SI || SI->getPointerOperand()->stripPointerCasts() != Addr)
          continue;
        Value *StoredVal = SI->getValueOperand();
        // Check if stored value is a call with known return type
        if (auto *CI = dyn_cast<CallInst>(StoredVal)) {
          Function *Callee = CI->getCalledFunction();
          if (Callee) {
            std::string CalleeRet = getReturnTypeFromDebugInfo(*Callee);
            if (!CalleeRet.empty())
              bodyRetTypes.insert(CalleeRet);
          }
        }
        // Check debug info on the stored value
        std::set<std::string> DbgTypes;
        resolveStructTypesFromDebugInfo(StoredVal, DbgTypes);
        bodyRetTypes.insert(DbgTypes.begin(), DbgTypes.end());
      }
    }
  }

  // Resolution logic:
  // - If the signature has a concrete struct type, prefer it (most authoritative)
  // - If the signature says void* but body analysis found a type, use the body type
  // - If body analysis found multiple types, use signature as tiebreaker
  // - If nothing found, return empty (void*/primitive — no sealing)

  if (!sigRetType.empty()) {
    // Signature has a concrete struct type — use it
    return sigRetType;
  }

  if (bodyRetTypes.size() == 1) {
    // Body analysis found exactly one type, signature was void* or empty
    return *bodyRetTypes.begin();
  }

  if (bodyRetTypes.size() > 1) {
    // Multiple types found in body — ambiguous, don't seal
    // (Could happen with generic container functions)
    return "";
  }

  // Nothing found — void*/primitive return
  return "";
}

/// Collect struct types from downstream uses of a value (via GEPs).
static void collectStructTypesFromUses(Value *V,
                                       std::set<StructType *> &Types,
                                       unsigned Depth = 8) {
  if (Depth == 0)
    return;
  for (User *U : V->users()) {
    if (auto *GEP = dyn_cast<GetElementPtrInst>(U)) {
      if (auto *ST = getGEPStructType(GEP))
        Types.insert(ST);
    }
    if (auto *SI = dyn_cast<StoreInst>(U)) {
      Value *StoreAddr = SI->getPointerOperand();
      for (User *LU : StoreAddr->users()) {
        if (auto *LI = dyn_cast<LoadInst>(LU))
          collectStructTypesFromUses(LI, Types, Depth - 1);
      }
    }
    if (auto *PHI = dyn_cast<PHINode>(U))
      collectStructTypesFromUses(PHI, Types, Depth - 1);
  }
}

// ============================================================================
// Debug info: optional field name resolution
// ============================================================================

/// Build a map from (struct name, field index) -> field name using debug info.
/// Struct name matching: LLVM names structs as "struct.foo" while debug info
/// uses "foo". We strip the "struct." prefix when matching.
static void buildFieldNameMap(
    Module &M,
    std::map<std::string, std::map<unsigned, std::string>> &FieldNames) {

  // Process a DICompositeType: extract member names
  auto processComposite = [&](DICompositeType *CT) {
    if (!CT || CT->getTag() != dwarf::DW_TAG_structure_type)
      return;
    StringRef DIName = CT->getName();
    if (DIName.empty())
      return;

    std::string LLVMName = ("struct." + DIName).str();
    if (FieldNames.count(LLVMName))
      return; // already processed

    auto Elements = CT->getElements();
    unsigned FieldIdx = 0;
    for (auto *Element : Elements) {
      if (auto *Member = dyn_cast<DIDerivedType>(Element)) {
        if (Member->getTag() == dwarf::DW_TAG_member) {
          StringRef FName = Member->getName();
          if (!FName.empty())
            FieldNames[LLVMName][FieldIdx] = FName.str();
          FieldIdx++;
        }
      }
    }
  };

  // Unwrap pointer/typedef/const/volatile to find the underlying composite type
  std::function<DICompositeType *(DIType *)> unwrapType =
      [&](DIType *DT) -> DICompositeType * {
    if (!DT)
      return nullptr;
    if (auto *CT = dyn_cast<DICompositeType>(DT))
      return CT;
    if (auto *DDT = dyn_cast<DIDerivedType>(DT)) {
      // Pointer, typedef, const, volatile, restrict all wrap a base type
      unsigned Tag = DDT->getTag();
      if (Tag == dwarf::DW_TAG_pointer_type ||
          Tag == dwarf::DW_TAG_typedef ||
          Tag == dwarf::DW_TAG_const_type ||
          Tag == dwarf::DW_TAG_volatile_type ||
          Tag == dwarf::DW_TAG_restrict_type) {
        return unwrapType(
            const_cast<DIType *>(
                dyn_cast_or_null<DIType>(DDT->getBaseType())));
      }
    }
    return nullptr;
  };

  // Scan all named metadata for DICompositeType nodes
  // This catches struct types that appear anywhere in debug info
  std::set<const MDNode *> Visited;
  std::function<void(const MDNode *)> scanMetadata =
      [&](const MDNode *MD) {
    if (!MD || !Visited.insert(MD).second)
      return;
    if (auto *CT = dyn_cast<DICompositeType>(MD))
      processComposite(const_cast<DICompositeType *>(CT));
    for (unsigned i = 0; i < MD->getNumOperands(); ++i) {
      if (auto *SubMD = dyn_cast_or_null<MDNode>(MD->getOperand(i)))
        scanMetadata(SubMD);
    }
  };

  // Scan compile unit metadata trees
  NamedMDNode *CUs = M.getNamedMetadata("llvm.dbg.cu");
  if (CUs) {
    for (MDNode *CU_MD : CUs->operands())
      scanMetadata(CU_MD);
  }

  // Scan all function subprogram metadata
  for (Function &F : M) {
    if (DISubprogram *SP = F.getSubprogram())
      scanMetadata(SP);
  }
}

// ============================================================================
// Per-function analysis: track struct field accesses via GEP
// ============================================================================

/// For a given function, find all struct field accesses (GEPs on struct types)
/// and trace which function parameters they originate from.
///
/// Returns a map: struct_name -> set of field indices accessed.
/// Also populates ParamTypeMap: param_index -> set of struct names that
/// the parameter is used as.
///
/// Side effect: attaches "seal.field_access" metadata to each instruction
/// that accesses a struct field, so the instrumentation pass can find them
/// without re-doing the analysis.  Metadata format:
///   !seal.field_access !{ !"struct.foo_data", i32 <field_index> }
static void analyzeFunctionFieldAccesses(
    Function &F,
    std::map<std::string, std::set<unsigned>> &FieldAccesses,
    std::map<unsigned, std::set<std::string>> &ParamTypeMap,
    std::map<std::string, std::set<unsigned>> &AddressTakenFields,
    // NEW (embedded-foreign-field): container name -> (field index -> field
    // struct type name), for by-value embedded struct members whose address is
    // taken. Ownership is resolved downstream (python); this only records the
    // structural fact. Distinct from AddressTakenFields — does not modify it.
    std::map<std::string, std::map<unsigned, std::string>> &EmbeddedStructFields) {

  LLVMContext &Ctx = F.getContext();
  Type *I32Ty = Type::getInt32Ty(Ctx);

  // Helper: attach !seal.field_access metadata to an instruction
  auto attachFieldAccessMD = [&](Instruction *I, StringRef SName,
                                 unsigned FieldIdx) {
    MDNode *MD = MDNode::get(Ctx, {
        MDString::get(Ctx, SName),
        ConstantAsMetadata::get(ConstantInt::get(I32Ty, FieldIdx))
    });
    I->setMetadata("seal.field_access", MD);
  };

  // Helper: attach !seal.embedded_field metadata (container, field struct type,
  // field index) to a GEP that derives the address of a by-value embedded
  // struct member. The seal pass uses this to locate the derivation site.
  auto attachEmbeddedFieldMD = [&](Instruction *I, StringRef Container,
                                   StringRef FieldType, unsigned FieldIdx) {
    MDNode *MD = MDNode::get(Ctx, {
        MDString::get(Ctx, Container),
        MDString::get(Ctx, FieldType),
        ConstantAsMetadata::get(ConstantInt::get(I32Ty, FieldIdx))
    });
    I->setMetadata("seal.embedded_field", MD);
  };

  // Phase 1: collect all struct GEP accesses in this function
  // Also build a map from GEP base pointer -> (struct, field_index)
  for (auto &I : instructions(F)) {
    auto *GEP = dyn_cast<GetElementPtrInst>(&I);
    if (!GEP)
      continue;
    auto *ST = getGEPStructType(GEP);
    if (!ST || !ST->hasName())
      continue;
    // Extract field index: for struct GEPs, index 0 is the pointer deref,
    // index 1 is the struct field index
    if (GEP->getNumIndices() >= 2) {
      auto IdxIt = GEP->idx_begin();
      ++IdxIt; // skip first index (pointer deref)
      if (auto *CI = dyn_cast<ConstantInt>(*IdxIt)) {
        unsigned FieldIdx = CI->getZExtValue();
        std::string SName = getStructName(ST);
        FieldAccesses[SName].insert(FieldIdx);
        attachFieldAccessMD(GEP, SName, FieldIdx);

        // Check if any user takes the address of this field rather than
        // loading from or storing to it.  Address-of-field on a sealed
        // struct cannot be handled by accessor replacement (the caller
        // needs a raw pointer into the struct's memory).
        for (User *U : GEP->users()) {
          if (isa<LoadInst>(U))
            continue;  // read — handled by accessor getter
          if (auto *SI = dyn_cast<StoreInst>(U)) {
            if (SI->getPointerOperand() == GEP)
              continue;  // write to field — handled by accessor setter
            // Storing the GEP result as a value means address escapes
          }
          // Any other use: call argument, return, PHI, bitcast, etc.
          AddressTakenFields[SName].insert(FieldIdx);
          break;  // one non-load/store user is enough
        }

        // NEW (embedded-foreign-field candidate): if the address of this field
        // was taken AND the field's own type is a named (by-value) struct AND
        // this GEP's result is EXACTLY that embedded struct's address (not a
        // deeper sub-field), record it. Ownership (owned by another compartment?)
        // is resolved later in the python analyzer. This is additive: it does
        // not read or change AddressTakenFields' effect on existing paths.
        auto AtIt = AddressTakenFields.find(SName);
        bool AddrTaken = AtIt != AddressTakenFields.end() &&
                         AtIt->second.count(FieldIdx);
        if (AddrTaken && FieldIdx < ST->getNumElements()) {
          auto *FieldST = dyn_cast<StructType>(ST->getElementType(FieldIdx));
          if (FieldST && FieldST->hasName() &&
              GEP->getResultElementType() == FieldST) {
            std::string FieldTypeName = getStructName(FieldST);
            EmbeddedStructFields[SName][FieldIdx] = FieldTypeName;
            attachEmbeddedFieldMD(GEP, SName, FieldTypeName, FieldIdx);
          }
        }
      }
    }
  }

  // Phase 2: trace function parameters to struct types they're used as
  for (auto &Arg : F.args()) {
    if (!Arg.getType()->isPointerTy())
      continue;

    unsigned ArgIdx = Arg.getArgNo();
    SmallPtrSet<Value *, 32> Visited;
    SmallVector<Value *, 32> Worklist;
    Worklist.push_back(&Arg);
    Visited.insert(&Arg);

    while (!Worklist.empty()) {
      Value *V = Worklist.pop_back_val();
      for (User *U : V->users()) {
        // Direct GEP on a struct type
        if (auto *GEP = dyn_cast<GetElementPtrInst>(U)) {
          if (auto *ST = getGEPStructType(GEP)) {
            if (ST->hasName())
              ParamTypeMap[ArgIdx].insert(getStructName(ST));
          }
        }
        // Follow through loads
        if (auto *LI = dyn_cast<LoadInst>(U)) {
          if (Visited.insert(LI).second)
            Worklist.push_back(LI);
        }
        // Follow through stores (value stored -> loads from same address)
        if (auto *SI = dyn_cast<StoreInst>(U)) {
          if (SI->getValueOperand() == V) {
            Value *Addr = SI->getPointerOperand();
            for (User *SU : Addr->users()) {
              if (auto *LI = dyn_cast<LoadInst>(SU)) {
                if (Visited.insert(LI).second)
                  Worklist.push_back(LI);
              }
            }
          }
        }
        // Follow through PHI nodes
        if (auto *PHI = dyn_cast<PHINode>(U)) {
          if (Visited.insert(PHI).second)
            Worklist.push_back(PHI);
        }
      }
    }

    // Phase 2b: if GEP-based tracing found no struct type for this param,
    // fall back to debug info
    if (ParamTypeMap.find(ArgIdx) == ParamTypeMap.end() ||
        ParamTypeMap[ArgIdx].empty()) {
      // Try resolving from debug intrinsics on the argument value
      std::set<std::string> DbgTypes;
      resolveStructTypesFromDebugInfo(&Arg, DbgTypes);
      for (auto &T : DbgTypes)
        ParamTypeMap[ArgIdx].insert(T);
    }
  }

  // Phase 2c: if debug intrinsics didn't help either, try the function's
  // DISubprogram signature for any remaining unresolved pointer params.
  // Also collect direct pointer-to-struct params for field-0 detection
  // in Phase 3 (avoids re-querying DISubprogram).
  //
  // We distinguish two things from the DISubprogram:
  //  - getStructNameFromDIType: walks through multiple pointer levels
  //    (used for ParamTypeMap — "this param involves struct foo somehow")
  //  - getDirectPointeeStructName: requires exactly one pointer level
  //    (used for field-0 detection — "this param IS a struct foo *")
  SmallVector<std::pair<Value *, std::string>, 16> StructPtrValues;
  {
    DISubprogram *SP = F.getSubprogram();
    if (SP) {
      DISubroutineType *SRT = SP->getType();
      if (SRT) {
        auto TypeArray = SRT->getTypeArray();
        // Element 0 is return type, 1..N are params
        for (unsigned i = 1; i < TypeArray.size(); ++i) {
          DIType *ParamDIType = TypeArray[i];
          if (!ParamDIType)
            continue;
          unsigned ArgIdx = i - 1;

          // Fill ParamTypeMap gaps (multi-level pointer resolution)
          if (ParamTypeMap.find(ArgIdx) == ParamTypeMap.end() ||
              ParamTypeMap[ArgIdx].empty()) {
            std::string TypeName = getStructNameFromDIType(ParamDIType);
            if (!TypeName.empty())
              ParamTypeMap[ArgIdx].insert(TypeName);
          }

          // Collect direct pointer-to-struct params for Phase 3 field-0
          if (ArgIdx < F.arg_size()) {
            std::string SName = getDirectPointeeStructName(ParamDIType);
            if (!SName.empty()) {
              Argument *Arg = F.getArg(ArgIdx);
              if (Arg->getType()->isPointerTy())
                StructPtrValues.push_back({Arg, SName});
            }
          }
        }
      }
    }
  }

  // Phase 3: detect field-0 accesses via debug info.
  //
  // When accessing field 0 of a struct, LLVM skips the GEP because field 0
  // is at offset 0:  `load ptr, ptr %struct_ptr`  gives field 0 directly.
  // Our Phase 1 only tracks GetElementPtrInst, so field-0 accesses are
  // invisible. Here we use debug info to find pointer-to-struct values
  // and check if they are directly loaded/stored from (without a GEP).
  //
  // StructPtrValues was partially populated above (Phase 2c) with function
  // parameters that are direct pointer-to-struct. Below we also add local
  // variables discovered via dbg.declare/dbg.value intrinsics.
  //
  // For each value identified as `pointer_to_struct`, if it is used as the
  // pointer operand of a LoadInst or StoreInst (not via GEP), that's a
  // field-0 access.
  {
    // (a) Function parameters: already in StructPtrValues from Phase 2c above

    // (b) Local variables via debug intrinsics
    for (auto &I : instructions(F)) {
      auto *DVI = dyn_cast<DbgVariableIntrinsic>(&I);
      if (!DVI)
        continue;
      DILocalVariable *Var = DVI->getVariable();
      if (!Var)
        continue;
      std::string SName = getDirectPointeeStructName(Var->getType());
      if (SName.empty())
        continue;
      // The debug intrinsic's value operand is the pointer-to-struct
      Value *V = DVI->getVariableLocationOp(0);
      if (!V || !V->getType()->isPointerTy())
        continue;
      StructPtrValues.push_back({V, SName});
    }

    // For each pointer-to-struct value, check if it's directly loaded/stored
    // from (without an intervening GEP) — that's a field-0 access.
    //
    // There are two cases:
    //  - PtrVal is an Argument (direct struct pointer): check if PtrVal is
    //    used as the pointer operand of a load/store.
    //  - PtrVal is an AllocaInst (from dbg.declare): the alloca holds the
    //    address of the local variable. Loading from alloca gives the struct
    //    pointer. We then check if THAT loaded value is used as the pointer
    //    operand of a load/store.
    //
    // We tag ALL matching load/store instructions with metadata (not just
    // the first one), so the instrumentation pass can find every access point.
    for (auto &[PtrVal, SName] : StructPtrValues) {
      // Collect all values that are the actual struct pointer
      SmallVector<Value *, 8> StructPtrs;

      if (isa<AllocaInst>(PtrVal)) {
        // dbg.declare case: alloca holds address of the pointer variable.
        // Loading from alloca gives us the struct pointer.
        for (User *U : PtrVal->users()) {
          if (auto *LI = dyn_cast<LoadInst>(U))
            StructPtrs.push_back(LI);
        }
      } else {
        // Argument or other direct value — it IS the struct pointer
        StructPtrs.push_back(PtrVal);
      }

      for (Value *SP : StructPtrs) {
        for (User *U : SP->users()) {
          // Direct load from the struct pointer = field-0 read
          if (auto *LI = dyn_cast<LoadInst>(U)) {
            if (LI->getPointerOperand() == SP) {
              FieldAccesses[SName].insert(0);
              attachFieldAccessMD(LI, SName, 0);
            }
          }
          // Direct store to the struct pointer = field-0 write
          if (auto *SI = dyn_cast<StoreInst>(U)) {
            if (SI->getPointerOperand() == SP) {
              FieldAccesses[SName].insert(0);
              attachFieldAccessMD(SI, SName, 0);
            }
          }
        }
      }
    }
  }
}

// ============================================================================
// External call analysis: struct types flowing through call arguments/returns
// ============================================================================

struct ExternalCallInfo {
  std::string CalleeName;
  std::string CallerFunc;
  std::vector<std::string> ArgStructTypes; // per-arg: struct type name or ""
  std::string ReturnStructType;            // struct type of return val, or ""
};

/// Analyze external (declared, not defined) function calls in function F.
static void analyzeExternalCalls(
    Function &F,
    std::vector<ExternalCallInfo> &Calls) {

  for (auto &I : instructions(F)) {
    auto *CB = dyn_cast<CallBase>(&I);
    if (!CB)
      continue;
    Function *Callee = CB->getCalledFunction();
    if (!Callee || !Callee->isDeclaration())
      continue;
    // Skip LLVM intrinsics and debug intrinsics
    if (Callee->isIntrinsic())
      continue;
    StringRef CalleeName = Callee->getName();
    if (CalleeName.startswith("llvm."))
      continue;

    ExternalCallInfo Info;
    Info.CalleeName = CalleeName.str();
    Info.CallerFunc = F.getName().str();

    // Analyze each argument: trace backward to find struct types
    for (unsigned i = 0; i < CB->arg_size(); ++i) {
      Value *Arg = CB->getArgOperand(i);
      if (!Arg->getType()->isPointerTy()) {
        Info.ArgStructTypes.push_back("");
        continue;
      }

      // Skip stack-allocated arguments.  The sealing model only covers
      // heap-allocated shared objects: a sealed capability is a contract
      // that the pointee was allocated by the owning compartment on the heap.
      // Stack variables are local to the calling compartment's own stack frame;
      // sealing a pointer to them before a cross-compartment call is both
      // incorrect (the callee cannot unseal it) and meaningless (the stack is
      // not shared state being protected).
      //
      // The check is: after stripping bitcasts / addrspacecasts / zero-index
      // GEPs (via stripPointerCasts), is the base value an AllocaInst?
      //
      // Importantly, stripPointerCasts does NOT strip through LoadInst.  This
      // means a heap pointer that happens to be stored in a local variable is
      // safe: the argument at the call site is a *load* from the alloca (a
      // LoadInst), not the alloca itself, so isa<AllocaInst> is false and the
      // heap pointer is processed normally.
      //
      // The concrete false positive this fixes: in ossl_connect_common,
      //   struct alpn_proto_buf proto;          // stack-allocated
      //   SSL_CTX_set_alpn_protos(ctx, proto.data, proto.len);
      // proto.data is field 0, so the compiler emits no GEP and passes the
      // raw alloca (%25) directly.  Debug info resolves %25 as
      // struct.alpn_proto_buf (correct for %25, wrong for how it is used),
      // causing a spurious seal_before_call that seals the stack buffer before
      // handing it to OpenSSL, which then cannot dereference it.
      if (isa<AllocaInst>(Arg->stripPointerCasts())) {
        Info.ArgStructTypes.push_back("");
        continue;
      }

      // Resolve argument struct type using debug info only.
      // Previous GEP-based heuristics caused false positives: when
      // &struct->field (a sub-field pointer) was passed as an argument,
      // getGEPStructType() returned the parent struct type instead of
      // recognizing it as a pointer to the field's type.
      std::string Best;

      // Primary: debug info on the argument value itself
      {
        std::set<std::string> DbgTypes;
        resolveStructTypesFromDebugInfo(Arg, DbgTypes);
        if (!DbgTypes.empty())
          Best = *DbgTypes.begin();
      }

      // Fallback: callee's DISubprogram parameter types
      if (Best.empty()) {
        std::map<unsigned, std::string> CalleeParamTypes;
        getParamTypesFromDebugInfo(*Callee, CalleeParamTypes);
        if (CalleeParamTypes.count(i))
          Best = CalleeParamTypes[i];
      }

      Info.ArgStructTypes.push_back(Best);
    }

    // Analyze return value using debug info only (same rationale as args)
    if (CB->getType()->isPointerTy()) {
      // Primary: debug info on the call result
      std::set<std::string> DbgTypes;
      resolveStructTypesFromDebugInfo(CB, DbgTypes);
      if (!DbgTypes.empty())
        Info.ReturnStructType = *DbgTypes.begin();

      // Fallback: callee's DISubprogram return type
      if (Info.ReturnStructType.empty()) {
        Info.ReturnStructType = getReturnTypeFromDebugInfo(*Callee);
      }
    }

    Calls.push_back(std::move(Info));
  }
}

// ============================================================================
// Core analysis and JSON emission
// ============================================================================

static void runCrossCompartmentTypeAnalysis(Module &M) {
  // Assert that debug info is present — we rely on it for type resolution
  NamedMDNode *DbgCUs = M.getNamedMetadata("llvm.dbg.cu");
  if (!DbgCUs || DbgCUs->getNumOperands() == 0) {
    report_fatal_error(
        Twine("CrossCompartmentTypeAnalyzer: no debug info found in module '") +
        M.getModuleIdentifier() +
        "'. Compile with -g to include debug information.",
        /*gen_crash_diag=*/false);
  }

  const DataLayout &DL = M.getDataLayout();

  // ---- Build optional debug info field name map ----
  std::map<std::string, std::map<unsigned, std::string>> FieldNames;
  buildFieldNameMap(M, FieldNames);

  // ---- Collect struct type catalog ----
  struct StructFieldEntry {
    unsigned Index;
    std::string TypeStr;
    uint64_t Offset;
    uint64_t Size;
    std::string Name; // from debug info, or ""
  };
  struct StructCatalogEntry {
    std::string Name;
    uint64_t TotalSize;
    std::vector<StructFieldEntry> Fields;
  };

  std::vector<StructCatalogEntry> Catalog;
  std::set<std::string> KnownStructNames;

  for (StructType *ST : M.getIdentifiedStructTypes()) {
    if (ST->isOpaque() || !ST->hasName())
      continue;

    std::string SName = getStructName(ST);
    KnownStructNames.insert(SName);

    StructCatalogEntry Entry;
    Entry.Name = SName;

    const StructLayout *SL = DL.getStructLayout(ST);
    Entry.TotalSize = SL->getSizeInBytes();

    for (unsigned i = 0; i < ST->getNumElements(); ++i) {
      StructFieldEntry FE;
      FE.Index = i;
      FE.TypeStr = typeToString(ST->getElementType(i));
      FE.Offset = SL->getElementOffset(i);
      // Compute field size
      FE.Size = DL.getTypeAllocSize(ST->getElementType(i));
      // Optional: field name from debug info
      auto FNIt = FieldNames.find(SName);
      if (FNIt != FieldNames.end()) {
        auto FIt = FNIt->second.find(i);
        if (FIt != FNIt->second.end())
          FE.Name = FIt->second;
      }
      Entry.Fields.push_back(FE);
    }
    Catalog.push_back(Entry);
  }

  // ---- Analyze each defined function ----
  struct FunctionAnalysis {
    std::string Name;
    bool ExternallyVisible;
    std::map<std::string, std::set<unsigned>> FieldAccesses;
    std::map<std::string, std::set<unsigned>> AddressTakenFields;
    // NEW: container -> (field index -> embedded struct type name)
    std::map<std::string, std::map<unsigned, std::string>> EmbeddedStructFields;
    std::map<unsigned, std::set<std::string>> ParamTypes;
    std::vector<ExternalCallInfo> ExtCalls;
    std::string ReturnStructType;  // struct type returned by this function (from body analysis)
  };

  std::vector<FunctionAnalysis> FuncAnalyses;

  for (Function &F : M) {
    if (F.isDeclaration())
      continue;
    // Skip LLVM intrinsics
    if (F.isIntrinsic())
      continue;

    FunctionAnalysis FA;
    FA.Name = F.getName().str();
    FA.ExternallyVisible =
        (F.getLinkage() != GlobalValue::InternalLinkage &&
         F.getLinkage() != GlobalValue::PrivateLinkage) ||
        F.hasAddressTaken();

    analyzeFunctionFieldAccesses(F, FA.FieldAccesses, FA.ParamTypes,
                                FA.AddressTakenFields, FA.EmbeddedStructFields);
    analyzeExternalCalls(F, FA.ExtCalls);
    FA.ReturnStructType = analyzeReturnType(F);

    FuncAnalyses.push_back(std::move(FA));
  }

  // ---- Compute type flow summary ----
  // Types IN: struct types received as parameters in externally-visible functions
  // Types OUT: struct types passed to external calls
  struct TypeFlowEntry {
    std::string TypeName;
    bool FieldsAccessed;
  };

  std::map<std::string, bool> TypesIn;  // type_name -> fields_accessed
  std::map<std::string, bool> TypesOut;

  for (auto &FA : FuncAnalyses) {
    if (!FA.ExternallyVisible)
      continue;

    // Types received as params
    for (auto &[ParamIdx, StructNames] : FA.ParamTypes) {
      for (auto &SName : StructNames) {
        bool accessed = FA.FieldAccesses.count(SName) > 0 &&
                        !FA.FieldAccesses[SName].empty();
        // If already marked as accessed, keep it
        if (TypesIn.count(SName))
          TypesIn[SName] = TypesIn[SName] || accessed;
        else
          TypesIn[SName] = accessed;
      }
    }
  }

  for (auto &FA : FuncAnalyses) {
    for (auto &Call : FA.ExtCalls) {
      for (auto &ArgType : Call.ArgStructTypes) {
        if (ArgType.empty())
          continue;
        bool accessed = FA.FieldAccesses.count(ArgType) > 0 &&
                        !FA.FieldAccesses[ArgType].empty();
        if (TypesOut.count(ArgType))
          TypesOut[ArgType] = TypesOut[ArgType] || accessed;
        else
          TypesOut[ArgType] = accessed;
      }
      if (!Call.ReturnStructType.empty()) {
        bool accessed = FA.FieldAccesses.count(Call.ReturnStructType) > 0 &&
                        !FA.FieldAccesses[Call.ReturnStructType].empty();
        if (TypesIn.count(Call.ReturnStructType))
          TypesIn[Call.ReturnStructType] =
              TypesIn[Call.ReturnStructType] || accessed;
        else
          TypesIn[Call.ReturnStructType] = accessed;
      }
    }
  }

  // ---- Emit JSON to stderr ----
  errs() << "===CROSS_COMPARTMENT_JSON_BEGIN===\n";
  JSONEmitter J(errs());
  J.objectBegin();

  // Module name
  J.stringField("module", M.getModuleIdentifier());

  // Struct catalog
  J.arrayBegin("struct_catalog");
  for (auto &Entry : Catalog) {
    J.objectBegin();
    J.stringField("name", Entry.Name);
    J.intField("total_size", Entry.TotalSize);
    J.arrayBegin("fields");
    for (auto &FE : Entry.Fields) {
      J.objectBegin();
      J.intField("index", FE.Index);
      J.stringField("type", FE.TypeStr);
      J.intField("offset", FE.Offset);
      J.intField("size", FE.Size);
      if (!FE.Name.empty())
        J.stringField("name", FE.Name);
      J.objectEnd();
    }
    J.arrayEnd();
    J.objectEnd();
  }
  J.arrayEnd();

  // Defined functions
  J.arrayBegin("defined_functions");
  for (auto &FA : FuncAnalyses) {
    // Only emit functions that have struct-related activity
    if (FA.FieldAccesses.empty() && FA.ParamTypes.empty() &&
        FA.ExtCalls.empty() && FA.AddressTakenFields.empty() &&
        FA.EmbeddedStructFields.empty() &&
        FA.ReturnStructType.empty())
      continue;

    J.objectBegin();
    J.stringField("name", FA.Name);
    J.boolField("externally_visible", FA.ExternallyVisible);

    // Return type (from body analysis — used for seal_on_return decisions)
    if (!FA.ReturnStructType.empty())
      J.stringField("return_struct_type", FA.ReturnStructType);

    // Field accesses
    if (!FA.FieldAccesses.empty()) {
      J.objectBegin("struct_field_accesses");
      for (auto &[SName, Fields] : FA.FieldAccesses) {
        J.arrayBegin(SName);
        for (unsigned Idx : Fields)
          J.intValue(Idx);
        J.arrayEnd();
      }
      J.objectEnd();
    }

    // Address-taken fields (GEP result used as pointer, not just load/store)
    if (!FA.AddressTakenFields.empty()) {
      J.objectBegin("address_taken_fields");
      for (auto &[SName, Fields] : FA.AddressTakenFields) {
        J.arrayBegin(SName);
        for (unsigned Idx : Fields)
          J.intValue(Idx);
        J.arrayEnd();
      }
      J.objectEnd();
    }

    // NEW: by-value embedded struct members whose address is taken. Container ->
    // [ {index, field_type} ]. Ownership (foreign vs local) is resolved by the
    // python analyzer; this is the raw structural fact.
    if (!FA.EmbeddedStructFields.empty()) {
      J.objectBegin("embedded_struct_fields");
      for (auto &[SName, Fields] : FA.EmbeddedStructFields) {
        J.arrayBegin(SName);
        for (auto &[Idx, FieldType] : Fields) {
          J.objectBegin();
          J.intField("index", Idx);
          J.stringField("field_type", FieldType);
          J.objectEnd();
        }
        J.arrayEnd();
      }
      J.objectEnd();
    }

    // Parameter types
    if (!FA.ParamTypes.empty()) {
      J.objectBegin("param_struct_types");
      for (auto &[ParamIdx, StructNames] : FA.ParamTypes) {
        J.arrayBegin(std::to_string(ParamIdx));
        for (auto &SN : StructNames)
          J.stringValue(SN);
        J.arrayEnd();
      }
      J.objectEnd();
    }

    // External calls from this function
    if (!FA.ExtCalls.empty()) {
      J.arrayBegin("external_calls");
      for (auto &Call : FA.ExtCalls) {
        // NOTE: We intentionally emit ALL external calls, even those where
        // the caller's debug info couldn't resolve any struct types. The
        // Python pipeline (build_call_graph) cross-references with the
        // callee's param_struct_types from the callee's own manifest to
        // fill in types the caller couldn't resolve. This is critical for
        // the struct field dereference pattern (e.g., ssl->ctx): the caller's
        // resolveStructTypesFromDebugInfo can't follow load->GEP->load chains,
        // so it returns empty, but the callee's DISubprogram has the correct
        // param type. If we filter here, the call never reaches the Python
        // pipeline and the callee's type can never be applied.
        //
        // Previously this block filtered out calls with no struct types:
        //   bool hasStructArg = false;
        //   for (auto &A : Call.ArgStructTypes)
        //     if (!A.empty()) { hasStructArg = true; break; }
        //   if (!hasStructArg && Call.ReturnStructType.empty())
        //     continue;

        J.objectBegin();
        J.stringField("callee", Call.CalleeName);
        J.arrayBegin("arg_struct_types");
        for (auto &A : Call.ArgStructTypes) {
          if (A.empty())
            J.nullValue();
          else
            J.stringValue(A);
        }
        J.arrayEnd();
        if (!Call.ReturnStructType.empty())
          J.stringField("return_struct_type", Call.ReturnStructType);
        else
          J.nullField("return_struct_type");
        J.objectEnd();
      }
      J.arrayEnd();
    }

    J.objectEnd();
  }
  J.arrayEnd();

  // Type flow summary
  J.objectBegin("type_flow");

  J.arrayBegin("types_in");
  for (auto &[TName, Accessed] : TypesIn) {
    J.objectBegin();
    J.stringField("type", TName);
    J.boolField("fields_accessed", Accessed);
    J.objectEnd();
  }
  J.arrayEnd();

  J.arrayBegin("types_out");
  for (auto &[TName, Accessed] : TypesOut) {
    J.objectBegin();
    J.stringField("type", TName);
    J.boolField("fields_accessed", Accessed);
    J.objectEnd();
  }
  J.arrayEnd();

  J.objectEnd(); // type_flow

  J.objectEnd(); // root
  errs() << "\n===CROSS_COMPARTMENT_JSON_END===\n";
}

// ============================================================================
// New Pass Manager: PassInfoMixin-based module pass (LLVM 15+)
// ============================================================================
namespace {

struct CrossCompartmentTypeAnalyzer
    : public PassInfoMixin<CrossCompartmentTypeAnalyzer> {

  PreservedAnalyses run(Module &M, ModuleAnalysisManager & /*AM*/) {
    runCrossCompartmentTypeAnalysis(M);
    // We attach !seal.field_access metadata to instructions, so the IR
    // is modified.  Return none() so opt writes the annotated bitcode.
    return PreservedAnalyses::none();
  }

  static bool isRequired() { return true; }
};

} // end anonymous namespace

// ============================================================================
// New Pass Manager plugin registration
// ============================================================================
extern "C" LLVM_ATTRIBUTE_WEAK ::llvm::PassPluginLibraryInfo
llvmGetPassPluginInfo() {
  return {
      LLVM_PLUGIN_API_VERSION, "CrossCompartmentTypeAnalyzer", "0.1",
      [](PassBuilder &PB) {
        PB.registerPipelineParsingCallback(
            [](StringRef Name, ModulePassManager &MPM,
               ArrayRef<PassBuilder::PipelineElement>) {
              if (Name == "cross-compartment-type-analyzer") {
                MPM.addPass(CrossCompartmentTypeAnalyzer());
                return true;
              }
              return false;
            });
      }};
}
