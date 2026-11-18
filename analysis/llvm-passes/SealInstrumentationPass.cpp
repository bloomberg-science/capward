// Copyright 2026 Bloomberg Finance L.P.
// Distributed under the terms of the MIT license.

//===- SealInstrumentationPass.cpp - CHERI seal/unseal instrumentation ----===//
//
// Part of the CHERI static analysis project.
//
// This LLVM module pass reads an instrumentation config JSON (produced by
// seal_codegen.py) and inserts CHERI seal/unseal intrinsic calls at
// cross-compartment boundaries.
//
// Per-compartment sealing model:
//   - Each library gets ONE otype, stored in a file-scope static global.
//   - The owning library seals outgoing pointers and unseals incoming ones
//     using llvm.cheri.cap.seal / llvm.cheri.cap.unseal intrinsics directly.
//   - The sealing capability is private to each .so; under C18N, other
//     compartments cannot access it.
//   - No shared runtime library is needed.
//
// The pass reads a JSON config file specified via the -seal-config command
// line option. The JSON contains seal points and per-function instrumentation
// directives.
//
// Designed for LLVM 15+ (opaque pointers, new pass manager only).
//
//===----------------------------------------------------------------------===//

#include "llvm/IR/Module.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/DebugInfo.h"
#include "llvm/IR/DebugInfoMetadata.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/BinaryFormat/Dwarf.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/IR/PassManager.h"
#include "llvm/IR/DataLayout.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Passes/PassPlugin.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/ADT/StringSet.h"

#include <fstream>
#include <map>
#include <set>
#include <string>
#include <sstream>
#include <vector>

using namespace llvm;

#define DEBUG_TYPE "seal-instrument"

// ============================================================================
// Command-line options
// ============================================================================

static cl::opt<std::string> SealConfigFile(
    "seal-config",
    cl::desc("Path to instrumentation_config.json"),
    cl::value_desc("filename"),
    cl::init(""));

static cl::opt<std::string> SealModuleName(
    "seal-module-name",
    cl::desc("Library name of this module (e.g. openssl_merged) [REQUIRED]"),
    cl::value_desc("name"),
    cl::Required);

static cl::opt<int> SealOtype(
    "seal-otype",
    cl::desc("Otype value for this compartment (unique per library)"),
    cl::value_desc("integer"),
    cl::init(-1));

static cl::opt<int> SealOtypeBase(
    "seal-otype-base",
    cl::desc("Base offset for otype allocation (avoids rtld/system collision)"),
    cl::value_desc("integer"),
    cl::init(1024));

// Embedded-foreign-field sealing (a locally-owned struct embeds a foreign-owned
// struct BY VALUE and the consumer derives its address — e.g. curl's
// zlib_writer embedding z_stream). OPT-IN: off unless explicitly enabled.
//
//   opt ... -seal-embedded-fields ...        (or =true)
//
// The seal-at-derivation implementation rewrites every use of the derived
// pointer, which is wrong when a use is a direct field access rather than a
// handoff to the owner — see the nginx ngx_http_gzip_filter_add_data case,
// where field 0 aliases the derivation and the store faults on a sealed
// capability. Until that is resolved, builds default to leaving it out.
//
// This single switch drops the whole path: with no directives parsed, the
// module-participation gate, the owner's __seal_owned_<owner> export and the
// consumer's seal-at-derivation rewriting all become no-ops. A config may still
// carry an embedded_foreign_seals section; it is simply ignored, so the mode
// can be toggled without regenerating the config.
static cl::opt<bool> SealEmbeddedFields(
    "seal-embedded-fields",
    cl::desc("Apply embedded-foreign-field sealing (default: false)"),
    cl::init(false));

// ============================================================================
// Minimal JSON parser (just enough for our config format)
// ============================================================================

namespace {

/// Simple recursive-descent JSON value representation.
struct JSONValue {
  enum Kind { Null, Bool, Number, String, Array, Object };
  Kind kind = Null;
  bool boolVal = false;
  int64_t numVal = 0;
  std::string strVal;
  std::vector<JSONValue> arrVal;
  std::map<std::string, JSONValue> objVal;

  bool isNull() const { return kind == Null; }
  bool isBool() const { return kind == Bool; }
  bool isNumber() const { return kind == Number; }
  bool isString() const { return kind == String; }
  bool isArray() const { return kind == Array; }
  bool isObject() const { return kind == Object; }

  const JSONValue &operator[](const std::string &key) const {
    static JSONValue NullVal;
    auto it = objVal.find(key);
    return it != objVal.end() ? it->second : NullVal;
  }

  const JSONValue &operator[](size_t idx) const {
    static JSONValue NullVal;
    return idx < arrVal.size() ? arrVal[idx] : NullVal;
  }

  int64_t asInt(int64_t def = 0) const {
    return isNumber() ? numVal : def;
  }

  const std::string &asString() const {
    static std::string empty;
    return isString() ? strVal : empty;
  }

  bool asBool(bool def = false) const {
    return isBool() ? boolVal : def;
  }
};

class JSONParser {
  const std::string &Input;
  size_t Pos = 0;

  void skipWhitespace() {
    while (Pos < Input.size() && isspace(Input[Pos]))
      ++Pos;
  }

  char peek() {
    skipWhitespace();
    return Pos < Input.size() ? Input[Pos] : '\0';
  }

  char next() {
    skipWhitespace();
    return Pos < Input.size() ? Input[Pos++] : '\0';
  }

  std::string parseString() {
    if (next() != '"')
      return "";
    std::string result;
    while (Pos < Input.size() && Input[Pos] != '"') {
      if (Input[Pos] == '\\') {
        ++Pos;
        if (Pos < Input.size()) {
          switch (Input[Pos]) {
          case '"': result += '"'; break;
          case '\\': result += '\\'; break;
          case 'n': result += '\n'; break;
          case 't': result += '\t'; break;
          case 'r': result += '\r'; break;
          default: result += Input[Pos]; break;
          }
        }
      } else {
        result += Input[Pos];
      }
      ++Pos;
    }
    if (Pos < Input.size())
      ++Pos; // skip closing "
    return result;
  }

  JSONValue parseValue() {
    JSONValue val;
    char c = peek();

    if (c == '"') {
      val.kind = JSONValue::String;
      val.strVal = parseString();
    } else if (c == '{') {
      val.kind = JSONValue::Object;
      next(); // skip {
      if (peek() != '}') {
        do {
          std::string key = parseString();
          next(); // skip :
          val.objVal[key] = parseValue();
        } while (peek() == ',' && (next(), true));
      }
      next(); // skip }
    } else if (c == '[') {
      val.kind = JSONValue::Array;
      next(); // skip [
      if (peek() != ']') {
        do {
          val.arrVal.push_back(parseValue());
        } while (peek() == ',' && (next(), true));
      }
      next(); // skip ]
    } else if (c == 't') {
      val.kind = JSONValue::Bool;
      val.boolVal = true;
      Pos += 4; // true
    } else if (c == 'f') {
      val.kind = JSONValue::Bool;
      val.boolVal = false;
      Pos += 5; // false
    } else if (c == 'n') {
      val.kind = JSONValue::Null;
      Pos += 4; // null
    } else if (c == '-' || isdigit(c)) {
      val.kind = JSONValue::Number;
      size_t start = Pos;
      if (Input[Pos] == '-') ++Pos;
      while (Pos < Input.size() && (isdigit(Input[Pos]) || Input[Pos] == '.'))
        ++Pos;
      val.numVal = std::stoll(Input.substr(start, Pos - start));
    }
    return val;
  }

public:
  explicit JSONParser(const std::string &input) : Input(input) {}
  JSONValue parse() { return parseValue(); }
};

} // anonymous namespace

// ============================================================================
// Configuration data structures
// ============================================================================

namespace {

struct SealTypeInfo {
  int TypeId;
  std::string TypeName;   // e.g. "struct.ssl_ctx_st"
  std::string CName;      // e.g. "ssl_ctx_st"
  std::string Owner;      // e.g. "openssl_merged"
  bool NeedsAccessor;
};

struct SealPoint {
  std::string Library;     // Which library this point is in
  std::string Function;    // Function name
  std::string TypeName;    // LLVM struct type name
  int TypeId;
  std::string Owner;
  std::string Action;      // "opaque_holder", "replace_with_accessor", etc.
  std::vector<std::string> FieldsAccessed;
  std::vector<int> FieldIndices;

  // For manifest-based mode
  std::string CallerLib;
  std::string CallerFunc;
  std::string CalleeFunc;
  int ArgIndex = -1;
};

struct CatalogFieldInfo {
  int Index;
  std::string Name;
  std::string LLVMType;   // e.g. "i32", "ptr", "[32 x i8]"
};

struct CatalogEntry {
  std::string Owner;
  std::vector<CatalogFieldInfo> Fields;
};

// NEW path: a by-value embedded struct member whose type is owned by another
// compartment (container local, field foreign). The consumer seals the derived
// address via the owner's exported accessor; the owner exports that accessor.
struct EmbeddedForeignSeal {
  std::string ContainerType;   // e.g. "struct.zlib_writer"
  std::string Consumer;        // compartment that derives &container.field
  std::string FieldType;       // e.g. "struct.z_stream_s"
  std::string FieldOwner;      // compartment that owns FieldType (has its otype)
  int FieldTypeId = -1;
  int FieldIndex = -1;
  std::string Function;        // informational (a representative site)
};

struct InstrumentationConfig {
  int NumTypes = 0;
  std::vector<std::string> Libraries;
  std::vector<SealTypeInfo> Types;
  std::vector<SealPoint> SealPoints;
  std::vector<EmbeddedForeignSeal> EmbeddedForeignSeals;

  // Lookup maps built after loading
  std::map<std::string, int> TypeNameToId;
  std::map<std::string, std::string> TypeNameToOwner;
  std::set<std::string> SealableTypeNames;

  // Struct catalog: type_name -> field layout (for accessor generation)
  std::map<std::string, CatalogEntry> StructCatalog;

  // Per-function: which types need seal/unseal
  std::map<std::string, std::vector<const SealPoint*>> FunctionSealPoints;

  bool load(const std::string &path) {
    std::ifstream file(path);
    if (!file.is_open()) {
      errs() << "seal-instrument: cannot open config: " << path << "\n";
      return false;
    }

    std::string content((std::istreambuf_iterator<char>(file)),
                        std::istreambuf_iterator<char>());

    JSONParser parser(content);
    JSONValue root = parser.parse();
    if (!root.isObject()) {
      errs() << "seal-instrument: invalid JSON in config\n";
      return false;
    }

    NumTypes = root["num_types"].asInt();

    // Parse libraries
    if (root["libraries"].isArray()) {
      for (auto &lib : root["libraries"].arrVal)
        Libraries.push_back(lib.asString());
    }

    // Parse types
    if (root["types"].isArray()) {
      for (auto &t : root["types"].arrVal) {
        SealTypeInfo info;
        info.TypeId = t["type_id"].asInt();
        info.TypeName = t["type_name"].asString();
        info.CName = t["c_name"].asString();
        info.Owner = t["owner"].asString();
        info.NeedsAccessor = t["needs_accessor"].asBool();
        Types.push_back(info);
        TypeNameToId[info.TypeName] = info.TypeId;
        TypeNameToOwner[info.TypeName] = info.Owner;
        SealableTypeNames.insert(info.TypeName);
      }
    }

    // Parse seal points
    if (root["seal_points"].isArray()) {
      for (auto &sp : root["seal_points"].arrVal) {
        SealPoint point;
        point.Library = sp["library"].asString();
        point.Function = sp["function"].asString();
        point.TypeName = sp["type_name"].asString();
        point.TypeId = sp["type_id"].asInt();
        point.Owner = sp["owner"].asString();
        point.Action = sp["action"].asString();

        if (sp["fields_accessed"].isArray()) {
          for (auto &f : sp["fields_accessed"].arrVal)
            point.FieldsAccessed.push_back(f.asString());
        }
        if (sp["field_indices"].isArray()) {
          for (auto &f : sp["field_indices"].arrVal)
            point.FieldIndices.push_back(f.asInt());
        }

        point.CallerLib = sp["caller_lib"].asString();
        point.CallerFunc = sp["caller_func"].asString();
        point.CalleeFunc = sp["callee_func"].asString();
        point.ArgIndex = sp["arg_index"].asInt(-1);

        SealPoints.push_back(point);
      }
    }

    // Parse struct_catalog (for accessor function generation)
    if (root["struct_catalog"].isObject()) {
      for (auto &[typeName, catVal] : root["struct_catalog"].objVal) {
        CatalogEntry entry;
        entry.Owner = catVal["owner"].asString();
        if (catVal["fields"].isArray()) {
          for (auto &fv : catVal["fields"].arrVal) {
            CatalogFieldInfo fi;
            fi.Index = fv["index"].asInt();
            fi.Name = fv["name"].asString();
            if (fi.Name.empty())
              fi.Name = "field_" + std::to_string(fi.Index);
            fi.LLVMType = fv["type"].asString();
            entry.Fields.push_back(fi);
          }
        }
        StructCatalog[typeName] = std::move(entry);
      }
    }

    // Parse embedded_foreign_seals (opt-in path — see -seal-embedded-fields).
    // Skipping the parse is the single gate for the whole feature: everything
    // downstream keys off EmbeddedForeignSeals being non-empty.
    if (!SealEmbeddedFields) {
      if (root["embedded_foreign_seals"].isArray() &&
          !root["embedded_foreign_seals"].arrVal.empty())
        errs() << "seal-instrument: ignoring "
               << root["embedded_foreign_seals"].arrVal.size()
               << " embedded_foreign_seals directive(s) "
                  "(-seal-embedded-fields not set)\n";
    } else if (root["embedded_foreign_seals"].isArray()) {
      for (auto &e : root["embedded_foreign_seals"].arrVal) {
        EmbeddedForeignSeal efs;
        efs.ContainerType = e["container_type"].asString();
        efs.Consumer = e["consumer"].asString();
        efs.FieldType = e["field_type"].asString();
        efs.FieldOwner = e["field_owner"].asString();
        efs.FieldTypeId = (int)e["field_type_id"].asInt();
        efs.FieldIndex = (int)e["field_index"].asInt();
        efs.Function = e["function"].asString();
        EmbeddedForeignSeals.push_back(efs);
      }
    }

    // Build per-function lookup
    for (size_t i = 0; i < SealPoints.size(); i++) {
      auto &sp = SealPoints[i];
      std::string key = sp.Function.empty() ?
        (sp.CallerFunc.empty() ? sp.CalleeFunc : sp.CallerFunc) :
        sp.Function;
      if (!key.empty())
        FunctionSealPoints[key].push_back(&SealPoints[i]);
    }

    return true;
  }
};

} // anonymous namespace

// ============================================================================
// Instrumentation logic
// ============================================================================

namespace {

/// Get the pointer type appropriate for this module.
/// CHERI purecap uses address space 200 for all pointers.
/// Standard targets use address space 0.
PointerType *getModulePtrTy(Module &M) {
  unsigned AS = M.getDataLayout().getProgramAddressSpace();
  return PointerType::get(M.getContext(), AS);
}

/// Get the program address space (200 for CHERI purecap, 0 otherwise).
unsigned getModuleAS(Module &M) {
  return M.getDataLayout().getProgramAddressSpace();
}

/// Determine which library this module belongs to.
std::string getModuleName(const Module &M) {
  // SealModuleName is a required option (cl::Required)
  // so it's guaranteed to be non-empty at this point
  return SealModuleName;
}

/// True for anonymous / placeholder struct-or-union names that cannot be
/// soundly attributed to a compartment: clang's 'struct.anon',
/// 'struct.anon.269' (LTO-suffixed), anonymous unions 'union.anon[.N]',
/// '<anonymous-struct>', or empty. Under LTO these collide across unrelated
/// types, so sealing/accessoring them is unsound (e.g. memcached's cq->head
/// STAILQ getting libevent's cheri_accessor_anon_* -> unseal of an unsealed
/// pointer -> abort). Mirrors is_anonymous_struct() in seal_codegen.py; this is
/// defense-in-depth so a stray config entry can never regenerate that bug.
static bool isAnonymousStructName(StringRef Name) {
  StringRef N = Name;
  if (!N.consume_front("struct."))
    N.consume_front("union.");
  return N.empty() || N == "anon" || N.startswith("anon.") ||
         Name == "<anonymous-struct>";
}

/// Create the per-compartment sealing capability global and init function.
///
/// Emits into the module:
///   @__sealcap = internal global ptr addrspace(200) null
///   @.str.sealcap = private constant [23 x i8] c"security.cheri.sealcap\00"
///
///   define internal void @__seal_init() {
///     %root = alloca ptr addrspace(200)
///     %len  = alloca i64
///     store i64 16, ptr %len
///     call i32 @sysctlbyname(@.str.sealcap, %root, %len, null, 0)
///     %r = load ptr, %root
///     %s = call @llvm.cheri.cap.address.set(%r, otype_value)
///     %b = call @llvm.cheri.cap.bounds.set(%s, 1)
///     store %b, @__sealcap
///     ret void
///   }
GlobalVariable *createSealcapGlobal(Module &M, unsigned AS) {
  auto *PtrTy = PointerType::get(M.getContext(), AS);
  auto *GV = new GlobalVariable(
      M, PtrTy, false, GlobalValue::InternalLinkage,
      ConstantPointerNull::get(PtrTy), "__sealcap");
  GV->setAlignment(Align(16));
  return GV;
}

/// Create module-level global to store this compartment's code base address.
/// Initialized by __seal_init() from PCC at load time.  Used by Strategy D2
/// to distinguish intra-compartment indirect calls from cross-compartment ones.
GlobalVariable *createCodeBaseGlobal(Module &M) {
  auto *I64Ty = Type::getInt64Ty(M.getContext());
  auto *GV = new GlobalVariable(
      M, I64Ty, false, GlobalValue::InternalLinkage,
      ConstantInt::get(I64Ty, 0), "__compartment_code_base");
  GV->setAlignment(Align(8));
  return GV;
}

Function *createSealInitFunc(Module &M, GlobalVariable *SealcapGV,
                              GlobalVariable *CodeBaseGV,
                              int64_t OtypeValue, StringRef ModuleName) {
  unsigned AS = getModuleAS(M);
  auto *PtrTy = PointerType::get(M.getContext(), AS);
  auto *I64Ty = Type::getInt64Ty(M.getContext());
  auto *I32Ty = Type::getInt32Ty(M.getContext());
  auto *VoidTy = Type::getVoidTy(M.getContext());

  // Create __seal_init function
  auto *FTy = FunctionType::get(VoidTy, {}, false);
  auto *InitFn = Function::Create(FTy, GlobalValue::InternalLinkage,
                                   AS, "__seal_init", &M);
  InitFn->setCallingConv(CallingConv::C);

  auto *Entry = BasicBlock::Create(M.getContext(), "entry", InitFn);
  IRBuilder<> B(Entry);

  // Declare sysctlbyname
  auto *SysctlFTy = FunctionType::get(
      I32Ty, {PtrTy, PtrTy, PtrTy, PtrTy, I64Ty}, false);
  FunctionCallee SysctlFn = M.getOrInsertFunction("sysctlbyname", SysctlFTy);

  // Create the sysctl name string
  Constant *SealcapStr = B.CreateGlobalStringPtr(
      "security.cheri.sealcap", ".str.sealcap", AS);

  // Allocate stack space for root sealcap and length
  auto *RootAlloca = B.CreateAlloca(PtrTy, nullptr, "root");
  auto *LenAlloca = B.CreateAlloca(I64Ty, nullptr, "len");
  B.CreateStore(ConstantPointerNull::get(PtrTy), RootAlloca);
  B.CreateStore(ConstantInt::get(I64Ty, 16), LenAlloca);  // sizeof(capability)

  // Call sysctlbyname("security.cheri.sealcap", &root, &len, NULL, 0)
  Value *SysctlRet = B.CreateCall(SysctlFn, {
      SealcapStr, RootAlloca, LenAlloca,
      ConstantPointerNull::get(PtrTy),
      ConstantInt::get(I64Ty, 0)
  }, "sysctl_ret");

  // Load the root sealcap
  Value *Root = B.CreateLoad(PtrTy, RootAlloca, "root_cap");

  // Derive per-compartment sealing capability:
  //   sc = cheri_bounds_set(cheri_address_set(root, otype_base + otype), 1)
  // The base offset (default 1024) avoids collision with rtld's otypes (0-~515)
  Function *AddrSetFn = Intrinsic::getDeclaration(
      &M, Intrinsic::cheri_cap_address_set,
      {I64Ty});
  Function *BoundsSetFn = Intrinsic::getDeclaration(
      &M, Intrinsic::cheri_cap_bounds_set,
      {I64Ty});

  int64_t ActualOtype = SealOtypeBase + OtypeValue;
  Value *WithAddr = B.CreateCall(AddrSetFn,
      {Root, ConstantInt::get(I64Ty, ActualOtype)}, "sc_addr");
  Value *WithBounds = B.CreateCall(BoundsSetFn,
      {WithAddr, ConstantInt::get(I64Ty, 1)}, "sc_bounds");

  // Store the derived sealcap
  B.CreateStore(WithBounds, SealcapGV);

  // Store compartment code base from PCC.
  // Used by Strategy D2 to distinguish intra-compartment indirect calls
  // from cross-compartment ones at runtime.
  Function *PccGetFn = Intrinsic::getDeclaration(&M, Intrinsic::cheri_pcc_get);
  Value *PCC = B.CreateCall(PccGetFn, {}, "pcc");
  Function *BaseGetFn = Intrinsic::getDeclaration(
      &M, Intrinsic::cheri_cap_base_get, {I64Ty});
  Value *CodeBase = B.CreateCall(BaseGetFn, {PCC}, "code_base");
  B.CreateStore(CodeBase, CodeBaseGV);

  // --- Diagnostic verification ---
  // Emit fprintf(stderr, "seal-init: %s otype=%ld sysctl=%d root_tag=%d sealcap_tag=%d\n", ...)
  // to diagnose tag loss in __sealcap initialization.

  // Declare fprintf (variadic)
  auto *FprintfFTy = FunctionType::get(I32Ty, {PtrTy, PtrTy}, true);
  FunctionCallee FprintfFn = M.getOrInsertFunction("fprintf", FprintfFTy);

  // Get stderr via FreeBSD's __stderrp global
  auto *StderrGV = M.getOrInsertGlobal("__stderrp", PtrTy);

  // Format string and module name string
  Constant *FmtStr = B.CreateGlobalStringPtr(
      "seal-init: %s otype=%ld sysctl=%d root_tag=%d sealcap_tag=%d\n",
      ".str.seal_diag", AS);
  Constant *ModNameStr = B.CreateGlobalStringPtr(
      ModuleName, ".str.seal_modname", AS);

  // Get tag intrinsic: llvm.cheri.cap.tag.get
  Function *TagGetFn = Intrinsic::getDeclaration(
      &M, Intrinsic::cheri_cap_tag_get);

  // Check root sealcap tag
  Value *RootTag = B.CreateCall(TagGetFn, {Root}, "root_tag");
  Value *RootTagI32 = B.CreateZExt(RootTag, I32Ty, "root_tag_i32");

  // Reload __sealcap and check its tag
  Value *Reloaded = B.CreateLoad(PtrTy, SealcapGV, "sealcap_verify");
  Value *SealcapTag = B.CreateCall(TagGetFn, {Reloaded}, "sealcap_tag");
  Value *SealcapTagI32 = B.CreateZExt(SealcapTag, I32Ty, "sealcap_tag_i32");

  // Load stderr and call fprintf
  Value *Stderr = B.CreateLoad(PtrTy, StderrGV, "stderr");
  B.CreateCall(FprintfFn, {
      Stderr, FmtStr, ModNameStr,
      ConstantInt::get(I64Ty, ActualOtype),
      SysctlRet, RootTagI32, SealcapTagI32
  });

  B.CreateRetVoid();

  return InitFn;
}

/// Emit a check: call @llvm.cheri.cap.sealed.get(ptr) -> i1
Value *emitIsSealed(IRBuilder<> &B, Module &M, Value *Ptr) {
  auto *PtrTy = getModulePtrTy(M);
  Function *SealedGetFn = Intrinsic::getDeclaration(
      &M, Intrinsic::cheri_cap_sealed_get);
  return B.CreateCall(SealedGetFn, {Ptr}, "is_sealed");
}

// ---- Debug assert helper functions (created once per module) ----
//
// Three small internal functions that check a condition and abort:
//   __seal_assert_not_sealed(ptr) — abort if cheri_is_sealed(ptr)
//   __seal_assert_sealed(ptr)     — abort if !cheri_is_sealed(ptr)
//   __seal_assert_tag(ptr)        — abort if !cheri_tag_get(ptr)
//
// Each seal/unseal site just emits a call to these — no block splitting.

Function *getOrCreateAssertNotSealed(Module &M) {
  unsigned AS = getModuleAS(M);
  auto *PtrTy = PointerType::get(M.getContext(), AS);
  auto *VoidTy = Type::getVoidTy(M.getContext());

  if (Function *F = M.getFunction("__seal_assert_not_sealed"))
    return F;

  auto *FTy = FunctionType::get(VoidTy, {PtrTy}, false);
  auto *F = Function::Create(FTy, GlobalValue::InternalLinkage,
                              AS, "__seal_assert_not_sealed", &M);
  F->setCallingConv(CallingConv::C);

  auto *Entry = BasicBlock::Create(M.getContext(), "entry", F);
  auto *Fail = BasicBlock::Create(M.getContext(), "fail", F);
  auto *Ok = BasicBlock::Create(M.getContext(), "ok", F);

  IRBuilder<> B(Entry);
  Value *Ptr = F->getArg(0);
  Value *IsSealed = B.CreateCall(
      Intrinsic::getDeclaration(&M, Intrinsic::cheri_cap_sealed_get),
      {Ptr}, "sealed");
  B.CreateCondBr(IsSealed, Fail, Ok);

  IRBuilder<> FB(Fail);
  auto *AbortFTy = FunctionType::get(VoidTy, {}, false);
  FunctionCallee AbortFn = M.getOrInsertFunction("abort", AbortFTy);
  if (auto *AbortF = dyn_cast<Function>(AbortFn.getCallee()))
    AbortF->addFnAttr(Attribute::NoReturn);
  FB.CreateCall(AbortFn, {});
  FB.CreateUnreachable();

  IRBuilder<> OB(Ok);
  OB.CreateRetVoid();

  return F;
}

Function *getOrCreateAssertSealed(Module &M) {
  unsigned AS = getModuleAS(M);
  auto *PtrTy = PointerType::get(M.getContext(), AS);
  auto *VoidTy = Type::getVoidTy(M.getContext());

  if (Function *F = M.getFunction("__seal_assert_sealed"))
    return F;

  auto *FTy = FunctionType::get(VoidTy, {PtrTy}, false);
  auto *F = Function::Create(FTy, GlobalValue::InternalLinkage,
                              AS, "__seal_assert_sealed", &M);
  F->setCallingConv(CallingConv::C);

  auto *Entry = BasicBlock::Create(M.getContext(), "entry", F);
  auto *Fail = BasicBlock::Create(M.getContext(), "fail", F);
  auto *Ok = BasicBlock::Create(M.getContext(), "ok", F);

  IRBuilder<> B(Entry);
  Value *Ptr = F->getArg(0);
  Value *IsSealed = B.CreateCall(
      Intrinsic::getDeclaration(&M, Intrinsic::cheri_cap_sealed_get),
      {Ptr}, "sealed");
  B.CreateCondBr(IsSealed, Ok, Fail);  // abort if NOT sealed

  IRBuilder<> FB(Fail);
  auto *AbortFTy = FunctionType::get(VoidTy, {}, false);
  FunctionCallee AbortFn = M.getOrInsertFunction("abort", AbortFTy);
  if (auto *AbortF = dyn_cast<Function>(AbortFn.getCallee()))
    AbortF->addFnAttr(Attribute::NoReturn);
  FB.CreateCall(AbortFn, {});
  FB.CreateUnreachable();

  IRBuilder<> OB(Ok);
  OB.CreateRetVoid();

  return F;
}

Function *getOrCreateAssertTag(Module &M) {
  unsigned AS = getModuleAS(M);
  auto *PtrTy = PointerType::get(M.getContext(), AS);
  auto *VoidTy = Type::getVoidTy(M.getContext());

  if (Function *F = M.getFunction("__seal_assert_tag"))
    return F;

  auto *FTy = FunctionType::get(VoidTy, {PtrTy}, false);
  auto *F = Function::Create(FTy, GlobalValue::InternalLinkage,
                              AS, "__seal_assert_tag", &M);
  F->setCallingConv(CallingConv::C);

  auto *Entry = BasicBlock::Create(M.getContext(), "entry", F);
  auto *Fail = BasicBlock::Create(M.getContext(), "fail", F);
  auto *Ok = BasicBlock::Create(M.getContext(), "ok", F);

  IRBuilder<> B(Entry);
  Value *Ptr = F->getArg(0);
  Value *HasTag = B.CreateCall(
      Intrinsic::getDeclaration(&M, Intrinsic::cheri_cap_tag_get),
      {Ptr}, "tag");
  B.CreateCondBr(HasTag, Ok, Fail);  // abort if tag == 0

  IRBuilder<> FB(Fail);
  auto *AbortFTy = FunctionType::get(VoidTy, {}, false);
  FunctionCallee AbortFn = M.getOrInsertFunction("abort", AbortFTy);
  if (auto *AbortF = dyn_cast<Function>(AbortFn.getCallee()))
    AbortF->addFnAttr(Attribute::NoReturn);
  FB.CreateCall(AbortFn, {});
  FB.CreateUnreachable();

  IRBuilder<> OB(Ok);
  OB.CreateRetVoid();

  return F;
}

/// Emit a seal: call @llvm.cheri.cap.seal(ptr, sealcap)
/// With debug asserts: abort on double-seal or tag loss.
Value *emitSeal(IRBuilder<> &B, Module &M, Value *Ptr,
                GlobalVariable *SealcapGV) {
  auto *PtrTy = getModulePtrTy(M);

  // Assert: ptr must not already be sealed
  B.CreateCall(getOrCreateAssertNotSealed(M), {Ptr});

  // Perform the seal
  Function *SealIntrinsic = Intrinsic::getDeclaration(
      &M, Intrinsic::cheri_cap_seal);
  Value *Cap = B.CreateLoad(PtrTy, SealcapGV, "sealcap");
  Value *Sealed = B.CreateCall(SealIntrinsic, {Ptr, Cap}, "sealed");

  // Assert: result must have valid tag
  B.CreateCall(getOrCreateAssertTag(M), {Sealed});

  return Sealed;
}

/// Emit a runtime check: does the indirect call target a different compartment?
/// Compares the function pointer's code base against this compartment's code base.
/// Returns i1: true if cross-compartment, false if same compartment.
Value *emitIsExternalCall(IRBuilder<> &B, Module &M, Value *CalledOperand,
                          GlobalVariable *CodeBaseGV) {
  auto *I64Ty = Type::getInt64Ty(M.getContext());
  Function *BaseGet = Intrinsic::getDeclaration(
      &M, Intrinsic::cheri_cap_base_get, {I64Ty});
  Value *FpBase = B.CreateCall(BaseGet, {CalledOperand}, "fp.base");
  Value *MyBase = B.CreateLoad(I64Ty, CodeBaseGV, "my.code.base");
  return B.CreateICmpNE(FpBase, MyBase, "is.cross.compartment");
}

/// Emit an unseal: call @llvm.cheri.cap.unseal(ptr, sealcap)
/// With debug asserts: abort if input not sealed or result tag lost.
Value *emitUnseal(IRBuilder<> &B, Module &M, Value *Ptr,
                  GlobalVariable *SealcapGV) {
  auto *PtrTy = getModulePtrTy(M);

  // Assert: ptr must be sealed
  B.CreateCall(getOrCreateAssertSealed(M), {Ptr});

  // Perform the unseal
  Function *UnsealIntrinsic = Intrinsic::getDeclaration(
      &M, Intrinsic::cheri_cap_unseal);
  Value *Cap = B.CreateLoad(PtrTy, SealcapGV, "sealcap");
  Value *Unsealed = B.CreateCall(UnsealIntrinsic, {Ptr, Cap}, "unsealed");

  // Assert: result must have valid tag
  B.CreateCall(getOrCreateAssertTag(M), {Unsealed});

  return Unsealed;
}



/// Emit a guarded seal: only seal if the pointer is non-null and not already
/// sealed.  This handles two cases:
///   - NULL return values (e.g. BIO_new_file returning NULL on error)
///   - Already-sealed pointers (e.g. OPENSSL_sk_value returning a pointer
///     that was sealed by another function's seal-on-return)
///
///   if (ptr != null && !cheri_is_sealed(ptr))
///     ptr = cheri_seal(ptr, sealcap);
Value *emitGuardedSeal(IRBuilder<> &B, Module &M, Value *Ptr,
                        GlobalVariable *SealcapGV, Function *F) {
  auto *PtrTy = getModulePtrTy(M);

  BasicBlock *CurBB = B.GetInsertBlock();
  Instruction *SplitPt = &*B.GetInsertPoint();
  BasicBlock *MergeBB = CurBB->splitBasicBlock(SplitPt, "seal.merge");

  CurBB->getTerminator()->eraseFromParent();

  BasicBlock *CheckSealedBB = BasicBlock::Create(M.getContext(),
      "check.sealed", F, MergeBB);
  BasicBlock *SealBB = BasicBlock::Create(M.getContext(), "seal", F, MergeBB);

  // Check: ptr != null
  B.SetInsertPoint(CurBB);
  Value *IsNull = B.CreateICmpEQ(Ptr, ConstantPointerNull::get(PtrTy),
                                  "is_null");
  B.CreateCondBr(IsNull, MergeBB, CheckSealedBB);

  // Check: not already sealed
  IRBuilder<> CB(CheckSealedBB);
  Value *IsSealed = emitIsSealed(CB, M, Ptr);
  CB.CreateCondBr(IsSealed, MergeBB, SealBB);

  // Seal block
  IRBuilder<> SB(SealBB);
  Value *Sealed = emitSeal(SB, M, Ptr, SealcapGV);
  SB.CreateBr(MergeBB);

  // PHI: null/already-sealed paths keep original, seal path uses sealed value
  PHINode *Phi = PHINode::Create(PtrTy, 3, "ptr.sealed",
                                  &*MergeBB->getFirstInsertionPt());
  Phi->addIncoming(Ptr, CurBB);           // null path
  Phi->addIncoming(Ptr, CheckSealedBB);   // already sealed path
  Phi->addIncoming(Sealed, SealBB);       // freshly sealed

  B.SetInsertPoint(MergeBB, std::next(Phi->getIterator()));

  return Phi;
}

/// Emit a guarded unseal: only unseal if the pointer is non-null and sealed.
///   if (ptr != null && cheri_is_sealed(ptr))
///     ptr = cheri_unseal(ptr, sealcap);
///
/// Properly splits the current basic block so existing instructions
/// flow into the merge block.
Value *emitGuardedUnseal(IRBuilder<> &B, Module &M, Value *Ptr,
                          GlobalVariable *SealcapGV, Function *F) {
  auto *PtrTy = getModulePtrTy(M);

  // Split the current block at the builder's insert point.
  // Everything after the insert point moves to MergeBB.
  BasicBlock *CurBB = B.GetInsertBlock();
  Instruction *SplitPt = &*B.GetInsertPoint();
  BasicBlock *MergeBB = CurBB->splitBasicBlock(SplitPt, "unseal.merge");

  // Remove the unconditional branch that splitBasicBlock inserted
  CurBB->getTerminator()->eraseFromParent();

  // Create intermediate blocks
  BasicBlock *CheckSealedBB = BasicBlock::Create(M.getContext(),
      "check.sealed", F, MergeBB);
  BasicBlock *UnsealBB = BasicBlock::Create(M.getContext(),
      "unseal", F, MergeBB);

  // Check: ptr != null (in CurBB)
  B.SetInsertPoint(CurBB);
  Value *IsNull = B.CreateICmpEQ(Ptr, ConstantPointerNull::get(PtrTy),
                                  "is_null");
  B.CreateCondBr(IsNull, MergeBB, CheckSealedBB);

  // Check: cheri_is_sealed(ptr)
  IRBuilder<> CB(CheckSealedBB);
  Value *IsSealed = emitIsSealed(CB, M, Ptr);
  CB.CreateCondBr(IsSealed, UnsealBB, MergeBB);

  // Unseal block
  IRBuilder<> UB(UnsealBB);
  Value *Unsealed = emitUnseal(UB, M, Ptr, SealcapGV);
  UB.CreateBr(MergeBB);

  // Insert PHI at the beginning of MergeBB (before existing instructions)
  PHINode *Phi = PHINode::Create(PtrTy, 3, "ptr.unsealed",
                                  &*MergeBB->getFirstInsertionPt());
  Phi->addIncoming(Ptr, CurBB);             // null path: keep original
  Phi->addIncoming(Ptr, CheckSealedBB);     // not sealed: keep original
  Phi->addIncoming(Unsealed, UnsealBB);     // sealed: unsealed

  // Set builder to continue after the PHI in MergeBB
  B.SetInsertPoint(MergeBB, std::next(Phi->getIterator()));

  return Phi;
}

/// Emit a guarded seal for indirect calls: only seal if the pointer is
/// non-null AND the call target is cross-compartment.
///   if (ptr != null && is_external)
///     ptr = cheri_seal(ptr, sealcap);
///
/// IsExternal is an i1 value produced by emitIsExternalCall().
/// Properly splits the current basic block so existing instructions
/// flow into the merge block.
Value *emitGuardedSeal(IRBuilder<> &B, Module &M, Value *Ptr,
                        Value *IsExternal, GlobalVariable *SealcapGV,
                        Function *F) {
  auto *PtrTy = getModulePtrTy(M);

  // Split the current block at the builder's insert point.
  BasicBlock *CurBB = B.GetInsertBlock();
  Instruction *SplitPt = &*B.GetInsertPoint();
  BasicBlock *MergeBB = CurBB->splitBasicBlock(SplitPt, "gseal.merge");
  CurBB->getTerminator()->eraseFromParent();

  BasicBlock *CheckExtBB = BasicBlock::Create(M.getContext(),
      "check.external", F, MergeBB);
  BasicBlock *SealBB = BasicBlock::Create(M.getContext(),
      "gseal", F, MergeBB);

  // Check: ptr != null
  B.SetInsertPoint(CurBB);
  Value *IsNull = B.CreateICmpEQ(Ptr, ConstantPointerNull::get(PtrTy),
                                  "is_null");
  B.CreateCondBr(IsNull, MergeBB, CheckExtBB);

  // Check: is_external (cross-compartment)
  IRBuilder<> EB(CheckExtBB);
  EB.CreateCondBr(IsExternal, SealBB, MergeBB);

  // Seal block
  IRBuilder<> SB(SealBB);
  Value *Sealed = emitSeal(SB, M, Ptr, SealcapGV);
  SB.CreateBr(MergeBB);

  // PHI merges all three paths
  PHINode *Phi = PHINode::Create(PtrTy, 3, "ptr.gseal",
                                  &*MergeBB->getFirstInsertionPt());
  Phi->addIncoming(Ptr, CurBB);           // null path: keep original
  Phi->addIncoming(Ptr, CheckExtBB);      // same compartment: keep original
  Phi->addIncoming(Sealed, SealBB);       // cross-compartment: sealed

  B.SetInsertPoint(MergeBB, std::next(Phi->getIterator()));

  return Phi;
}

/// Replace all uses of OldVal with NewVal, except uses that are part of the
/// guard construct itself (the PHI node, null check, sealed check, and
/// unseal/seal call).  Uses in the merge block *after* the PHI are original
/// code and must be replaced.
void replaceUsesExceptGuard(Value *OldVal, Value *NewVal) {
  // Collect the specific guard instructions to exclude.
  // The guard blocks (check.sealed, unseal, check.sealcap, seal) contain
  // only guard instructions.  The merge block contains the PHI plus
  // original code — only the PHI itself should be excluded there.
  SmallPtrSet<Instruction *, 16> GuardInsts;
  SmallPtrSet<BasicBlock *, 8> PureGuardBBs;  // blocks with ONLY guard code

  if (auto *Phi = dyn_cast<PHINode>(NewVal)) {
    GuardInsts.insert(Phi);
    // The incoming blocks (check.sealed, unseal, etc.) are purely guard code
    for (unsigned i = 0; i < Phi->getNumIncomingValues(); ++i) {
      PureGuardBBs.insert(Phi->getIncomingBlock(i));
      if (auto *I = dyn_cast<Instruction>(Phi->getIncomingValue(i)))
        PureGuardBBs.insert(I->getParent());
    }
  }

  SmallVector<Use *, 16> UsesToReplace;
  for (auto &U : OldVal->uses()) {
    auto *UserInst = dyn_cast<Instruction>(U.getUser());
    if (!UserInst) continue;
    // Skip guard instructions (the PHI itself)
    if (GuardInsts.count(UserInst)) continue;
    // Skip instructions in pure guard blocks (check/unseal blocks)
    if (PureGuardBBs.count(UserInst->getParent())) continue;
    UsesToReplace.push_back(&U);
  }
  for (auto *U : UsesToReplace)
    U->set(NewVal);
}

/// Unwrap a DIType through pointer/typedef/const/volatile/restrict layers
/// to find the underlying DICompositeType (struct/union) name.
/// Returns the LLVM-style name (e.g. "struct.ssl_cipher_st") or empty string.
/// Handles anonymous structs behind typedefs (e.g. "typedef struct { ... } Foo")
/// by tracking the last typedef name seen during unwrapping.
static std::string getStructNameFromDIType(DIType *DT) {
  std::string LastTypedefName;
  for (unsigned Depth = 0; DT && Depth < 16; ++Depth) {
    if (auto *CT = dyn_cast<DICompositeType>(DT)) {
      if (CT->getTag() == dwarf::DW_TAG_structure_type ||
          CT->getTag() == dwarf::DW_TAG_union_type) {
        StringRef Name = CT->getName();
        if (!Name.empty())
          return ("struct." + Name).str();
        // Anonymous struct — use typedef name if available
        if (!LastTypedefName.empty())
          return ("struct." + LastTypedefName);
      }
      return "";
    }
    if (auto *DDT = dyn_cast<DIDerivedType>(DT)) {
      unsigned Tag = DDT->getTag();
      if (Tag == dwarf::DW_TAG_typedef) {
        LastTypedefName = DDT->getName().str();
        DT = dyn_cast_or_null<DIType>(DDT->getBaseType());
        continue;
      }
      if (Tag == dwarf::DW_TAG_pointer_type ||
          Tag == dwarf::DW_TAG_const_type ||
          Tag == dwarf::DW_TAG_volatile_type ||
          Tag == dwarf::DW_TAG_restrict_type) {
        DT = dyn_cast_or_null<DIType>(DDT->getBaseType());
        continue;
      }
    }
    break;
  }
  return "";
}

/// Extract the return type of a function pointer from a DISubroutineType.
/// The subroutine type's type array element 0 is the return type.
static std::string getReturnTypeFromDISubroutineType(DISubroutineType *SRT) {
  if (!SRT) return "";
  auto TypeArray = SRT->getTypeArray();
  if (TypeArray.size() < 1) return "";
  DIType *RetDIType = TypeArray[0];
  return getStructNameFromDIType(RetDIType);
}

/// Given a DIType for a struct field that is expected to be a function pointer,
/// extract the function pointer's return struct type name.
/// Unwraps: pointer → [typedef/const/volatile →] subroutine_type → return type.
static std::string getFnPtrReturnType(DIType *FieldDIType) {
  if (!FieldDIType) return "";
  auto *PtrDT = dyn_cast<DIDerivedType>(FieldDIType);
  if (!PtrDT || PtrDT->getTag() != dwarf::DW_TAG_pointer_type)
    return "";
  DIType *PointeeDT = dyn_cast_or_null<DIType>(PtrDT->getBaseType());
  // Unwrap typedef/const/volatile layers to reach subroutine type
  for (unsigned D = 0; PointeeDT && D < 8; ++D) {
    if (isa<DISubroutineType>(PointeeDT))
      break;
    if (auto *DD = dyn_cast<DIDerivedType>(PointeeDT)) {
      if (DD->getTag() == dwarf::DW_TAG_typedef ||
          DD->getTag() == dwarf::DW_TAG_const_type ||
          DD->getTag() == dwarf::DW_TAG_volatile_type) {
        PointeeDT = dyn_cast_or_null<DIType>(DD->getBaseType());
        continue;
      }
    }
    break;
  }
  if (auto *SRT = dyn_cast_or_null<DISubroutineType>(PointeeDT))
    return getReturnTypeFromDISubroutineType(SRT);
  return "";
}

/// Get the debug info struct name for a Value by tracing its dbg.value users.
/// LLVM may merge struct types with identical layouts, so the IR type name
/// (e.g. %struct.ssl_comp_st) may not match the actual source type
/// (e.g. version_info).  This function finds the real name from debug info.
/// Returns the LLVM-style name (e.g. "struct.version_info") or empty string.
static std::string getDebugStructName(Value *V) {
  SmallVector<DbgVariableIntrinsic *, 4> DbgIntrinsics;
  findDbgUsers(DbgIntrinsics, V);
  for (auto *DVI : DbgIntrinsics) {
    DILocalVariable *Var = DVI->getVariable();
    if (!Var) continue;
    std::string Name = getStructNameFromDIType(Var->getType());
    if (!Name.empty())
      return Name;
  }
  return "";
}

/// Given a struct name (LLVM-style, e.g. "struct.version_info") and a field
/// index, find the corresponding DICompositeType in the module's debug info
/// and return the debug info type of that field's member.
static DIType *findStructFieldDIType(Module &M, StringRef StructName,
                                     unsigned FieldIdx) {
  // Strip "struct." prefix for matching against debug info names
  StringRef BareName = StructName;
  if (BareName.startswith("struct."))
    BareName = BareName.drop_front(7);

  // Scan compile unit metadata for matching DICompositeType
  NamedMDNode *CUs = M.getNamedMetadata("llvm.dbg.cu");
  if (!CUs) return nullptr;

  // Recursive scan for DICompositeType with matching name.
  // Also matches typedefs to anonymous structs (e.g. "typedef struct { ... } version_info")
  // since the caller may pass the typedef name when the struct is anonymous.
  SmallPtrSet<const MDNode *, 32> Visited;
  std::function<const DICompositeType *(const MDNode *)> findType =
      [&](const MDNode *MD) -> const DICompositeType * {
    if (!MD || !Visited.insert(MD).second)
      return nullptr;
    if (auto *CT = dyn_cast<DICompositeType>(MD)) {
      if (CT->getTag() == dwarf::DW_TAG_structure_type &&
          CT->getName() == BareName)
        return CT;
    }
    if (auto *DDT = dyn_cast<DIDerivedType>(MD)) {
      if (DDT->getTag() == dwarf::DW_TAG_typedef &&
          DDT->getName() == BareName) {
        if (auto *CT = dyn_cast_or_null<DICompositeType>(DDT->getBaseType())) {
          if (CT->getTag() == dwarf::DW_TAG_structure_type)
            return CT;
        }
      }
    }
    for (unsigned i = 0; i < MD->getNumOperands(); ++i) {
      if (auto *SubMD = dyn_cast_or_null<MDNode>(MD->getOperand(i))) {
        if (auto *Found = findType(SubMD))
          return Found;
      }
    }
    return nullptr;
  };

  const DICompositeType *StructDI = nullptr;
  for (MDNode *CU_MD : CUs->operands()) {
    StructDI = findType(CU_MD);
    if (StructDI) break;
  }
  // Also check function subprograms
  if (!StructDI) {
    for (Function &F : M) {
      if (DISubprogram *SP = F.getSubprogram()) {
        StructDI = findType(SP);
        if (StructDI) break;
      }
    }
  }
  if (!StructDI) return nullptr;

  // Find the member at FieldIdx
  auto Elements = StructDI->getElements();
  unsigned MemberIdx = 0;
  for (auto *Element : Elements) {
    auto *Member = dyn_cast<DIDerivedType>(Element);
    if (!Member || Member->getTag() != dwarf::DW_TAG_member)
      continue;
    if (MemberIdx == FieldIdx)
      return dyn_cast_or_null<DIType>(Member->getBaseType());
    MemberIdx++;
  }
  return nullptr;
}

/// Resolve the struct return type of a CallInst from debug info.
/// Three resolution paths:
///   1. dbg.value/dbg.declare on the call result
///   2. Trace through stores to alloca, check alloca's debug info
///   3. For indirect calls: trace the function pointer back through load/GEP
///      to find the struct field it was loaded from, then extract the return
///      type from the function pointer's type in the struct's debug info
static std::string resolveCallReturnType(CallInst *CI, Module &M) {
  // 1. Check debug intrinsics directly referencing the call result
  SmallVector<DbgVariableIntrinsic *, 4> DbgIntrinsics;
  findDbgUsers(DbgIntrinsics, CI);
  for (auto *DVI : DbgIntrinsics) {
    DILocalVariable *Var = DVI->getVariable();
    if (!Var) continue;
    std::string Name = getStructNameFromDIType(Var->getType());
    if (!Name.empty())
      return Name;
  }

  // 2. Trace through stores: result stored to alloca, check alloca's debug info
  for (User *U : CI->users()) {
    auto *SI = dyn_cast<StoreInst>(U);
    if (!SI || SI->getValueOperand() != CI)
      continue;
    Value *Addr = SI->getPointerOperand()->stripPointerCasts();
    SmallVector<DbgVariableIntrinsic *, 4> AddrDbg;
    findDbgUsers(AddrDbg, Addr);
    for (auto *DVI : AddrDbg) {
      DILocalVariable *Var = DVI->getVariable();
      if (!Var) continue;
      std::string Name = getStructNameFromDIType(Var->getType());
      if (!Name.empty())
        return Name;
    }
  }

  // 3. For indirect calls: extract return type from the function pointer's
  //    type in the struct it was loaded from.
  //    Pattern: %fptr = load ptr, (GEP struct, 0, field_idx) → call ptr %fptr()
  //    The struct's debug info has the field's function pointer type, including
  //    its return type.
  if (!CI->getCalledFunction()) {
    Value *FPtr = CI->getCalledOperand()->stripPointerCasts();
    if (auto *LI = dyn_cast<LoadInst>(FPtr)) {
      Value *Addr = LI->getPointerOperand()->stripPointerCasts();
      if (auto *GEP = dyn_cast<GetElementPtrInst>(Addr)) {
        auto *SrcTy = dyn_cast<StructType>(GEP->getSourceElementType());
        if (SrcTy && SrcTy->hasName() && GEP->getNumIndices() >= 2) {
          auto IdxIt = GEP->idx_begin();
          ++IdxIt; // skip pointer deref index
          if (auto *FieldCI = dyn_cast<ConstantInt>(*IdxIt)) {
            unsigned FieldIdx = FieldCI->getZExtValue();
            std::string StructName = SrcTy->getName().str();

            // Try with the IR type name first
            DIType *FieldDIType = findStructFieldDIType(M, StructName, FieldIdx);
            std::string RetName = getFnPtrReturnType(FieldDIType);

            // Fallback: LLVM may merge struct types with identical layouts,
            // so the IR type name may differ from the source type name.
            // Trace the GEP base pointer's debug info to find the real name.
            if (RetName.empty()) {
              Value *BasePtr = GEP->getPointerOperand();
              std::string DbgStructName = getDebugStructName(BasePtr);
              if (!DbgStructName.empty() && DbgStructName != StructName) {
                FieldDIType = findStructFieldDIType(M, DbgStructName, FieldIdx);
                RetName = getFnPtrReturnType(FieldDIType);
              }
            }

            if (!RetName.empty())
              return RetName;
          }
        }
      }
    }
  }

  return "";
}

/// Resolve struct type name of an argument value from debug info.
///
/// NOTE: For direct calls, argument types come from the instrumentation
/// config (produced by CrossCompartmentTypeAnalyzer + seal_codegen.py).
/// For indirect calls, the config has no entries because the callee is
/// unknown at analysis time — getCalledFunction() returns null, so the
/// analyzer's analyzeExternalCalls() skips them (line 895), and there is
/// no callee function name to key a config entry on.
///
/// This function fills that gap by resolving the argument's type directly
/// from debug info at the IR level, using the same approach the analyzer's
/// analyzeExternalCalls() uses (resolveStructTypesFromDebugInfo), but
/// adapted to the simpler findDbgUsers/getStructNameFromDIType utilities
/// available in this pass.  This mirrors resolveCallReturnType (used by
/// Strategy 5b for indirect call return types) which exists in this pass
/// for the same reason.
static std::string resolveArgType(Value *Arg) {
  // 1. Check debug intrinsics on the arg value directly
  SmallVector<DbgVariableIntrinsic *, 4> DbgIntrinsics;
  findDbgUsers(DbgIntrinsics, Arg);
  for (auto *DVI : DbgIntrinsics) {
    DILocalVariable *Var = DVI->getVariable();
    if (!Var) continue;
    std::string Name = getStructNameFromDIType(Var->getType());
    if (!Name.empty()) return Name;
  }

  // 2. If arg is a load, check the loaded address's debug info
  if (auto *LI = dyn_cast<LoadInst>(Arg)) {
    Value *Addr = LI->getPointerOperand()->stripPointerCasts();
    SmallVector<DbgVariableIntrinsic *, 4> AddrDbg;
    findDbgUsers(AddrDbg, Addr);
    for (auto *DVI : AddrDbg) {
      DILocalVariable *Var = DVI->getVariable();
      if (!Var) continue;
      std::string Name = getStructNameFromDIType(Var->getType());
      if (!Name.empty()) return Name;
    }
  }

  return "";
}

/// Instrument a module based on the loaded configuration.
/// NEW path (embedded-foreign-field). Strip a trailing ".<digits>" LTO suffix
/// so metadata names and config names reconcile (e.g. struct.z_stream_s.7).
static std::string normEmbeddedName(StringRef N) {
  size_t Dot = N.rfind('.');
  if (Dot != StringRef::npos && Dot + 1 < N.size()) {
    bool AllDigits = true;
    for (size_t i = Dot + 1; i < N.size(); ++i)
      if (!isdigit((unsigned char)N[i])) { AllDigits = false; break; }
    if (AllDigits)
      return N.substr(0, Dot).str();
  }
  return N.str();
}

/// NEW path (owner side). Get or create the exported per-owner seal accessor
/// `__seal_owned_<owner>(ptr) -> ptr` in the OWNER's module. It seals the
/// incoming (unsealed) capability with this module's private sealcap (the
/// owner's otype) and returns it. Null / already-sealed inputs pass through.
static Function *getOrCreateSealOwnedAccessor(Module &M, StringRef Owner,
                                              GlobalVariable *SealcapGV) {
  std::string Name = ("__seal_owned_" + Owner).str();
  if (Function *Existing = M.getFunction(Name))
    return Existing;

  auto *PtrTy = getModulePtrTy(M);
  unsigned AS = getModuleAS(M);
  FunctionType *FTy = FunctionType::get(PtrTy, {PtrTy}, false);
  auto *F = Function::Create(FTy, GlobalValue::ExternalLinkage, AS, Name, &M);

  BasicBlock *Entry = BasicBlock::Create(M.getContext(), "entry", F);
  IRBuilder<> B(Entry);
  Value *Arg = F->getArg(0);
  ReturnInst *Ret = B.CreateRet(Arg);   // placeholder terminator
  B.SetInsertPoint(Ret);
  Value *Sealed = emitGuardedSeal(B, M, Arg, SealcapGV, F);
  Ret->setOperand(0, Sealed);
  return F;
}

/// NEW path (consumer side). Get or create an EXTERNAL declaration of the
/// owner's seal accessor in this (consumer) module, in the module's address
/// space so it links against the owner's definition.
static FunctionCallee getSealOwnedAccessorDecl(Module &M, StringRef Owner) {
  std::string Name = ("__seal_owned_" + Owner).str();
  auto *PtrTy = getModulePtrTy(M);
  FunctionType *FTy = FunctionType::get(PtrTy, {PtrTy}, false);
  if (Function *F = M.getFunction(Name))
    return FunctionCallee(FTy, F);
  auto *F = Function::Create(FTy, GlobalValue::ExternalLinkage, getModuleAS(M),
                             Name, &M);
  return FunctionCallee(FTy, F);
}

bool instrumentModule(Module &M, InstrumentationConfig &Config) {
  std::string ModName = getModuleName(M);
  errs() << "seal-instrument: instrumenting module '" << ModName << "'\n";
  errs() << "seal-instrument: " << Config.NumTypes << " sealable types, "
         << Config.SealPoints.size() << " seal points\n";

  // Check if this module owns any sealable types
  bool IsOwner = false;
  for (auto &t : Config.Types) {
    if (t.Owner == ModName) {
      IsOwner = true;
      break;
    }
  }

  // Also check if this module has any seal_before_call or accessor points
  bool HasCallSites = false;
  bool HasAccessorPoints = false;
  for (auto &sp : Config.SealPoints) {
    if ((sp.Action == "seal_before_call" || sp.Action == "unseal_after_call")
        && sp.CallerLib == ModName) {
      HasCallSites = true;
    }
    if (sp.Action == "replace_with_accessor" && sp.CallerLib == ModName) {
      HasAccessorPoints = true;
    }
  }

  // NEW path: does this module participate in any embedded-foreign-field seal
  // (as the consumer that derives it, or the owner that must export the seal
  // accessor)?
  bool HasEmbeddedForeign = false;
  for (auto &efs : Config.EmbeddedForeignSeals) {
    if (efs.Consumer == ModName || efs.FieldOwner == ModName) {
      HasEmbeddedForeign = true;
      break;
    }
  }

  if (!IsOwner && !HasCallSites && !HasAccessorPoints && !HasEmbeddedForeign) {
    errs() << "seal-instrument: module '" << ModName
           << "' has no owned types, no call sites, and no accessor points, "
           << "skipping\n";
    return false;
  }

  if (SealOtype < 0) {
    errs() << "seal-instrument: no -seal-otype specified, skipping\n";
    return false;
  }

  bool Modified = false;
  unsigned AS = getModuleAS(M);
  auto *PtrTy = getModulePtrTy(M);

  unsigned SealCount = 0;
  unsigned UnsealCount = 0;
  unsigned AccessorCount = 0;
  unsigned SealOnReturnCount = 0;
  unsigned SealBeforeCallCount = 0;
  unsigned SealD2Count = 0;
  unsigned UnsealOnEntryCount = 0;
  unsigned UnsealAfterCallCount = 0;
  unsigned UnsealStrategy5Count = 0;
  unsigned UnsealStrategy5bCount = 0;

  // ---- Create per-compartment sealing infrastructure ----
  //
  // Each library gets a file-scope static sealing capability and an
  // init function.  Under C18N, the static is private to this .so.
  // The code base global stores PCC base for compartment identification.

  GlobalVariable *SealcapGV = createSealcapGlobal(M, AS);
  GlobalVariable *CodeBaseGV = createCodeBaseGlobal(M);
  Function *InitFn = createSealInitFunc(M, SealcapGV, CodeBaseGV, SealOtype, SealModuleName);
  Modified = true;

  errs() << "seal-instrument: created __sealcap global and __seal_init() "
         << "with otype " << (SealOtypeBase + SealOtype)
         << " (base=" << SealOtypeBase << " + offset=" << SealOtype << ")\n";

  // ---- Build set of owned sealable types (used by D1 and D2) ----
  std::set<std::string> OwnedSealableTypes;
  for (auto &t : Config.Types) {
    if (t.Owner == ModName && Config.SealableTypeNames.count(t.TypeName)
        && !isAnonymousStructName(t.TypeName))
      OwnedSealableTypes.insert(t.TypeName);
  }

  // ---- NEW path: embedded-foreign-field seals ----
  //
  // A struct owned by the CURRENT (consumer) compartment embeds, BY VALUE, a
  // struct owned by ANOTHER compartment, and the consumer derives its address
  // (e.g. curl's `z_stream *z = &zp->z;` where zlib_writer is curl's and the
  // embedded z_stream is zlib's). The derived pointer is an UNSEALED interior
  // capability, but the field's owner unseals it on entry / its accessors
  // expect it sealed → crash. We seal it at the derivation via the owner's
  // exported accessor and replace all downstream uses with the sealed cap.
  //
  //   Role A (owner):    export __seal_owned_<owner>(ptr)->ptr
  //   Role B (consumer): at each !seal.embedded_field GEP matching a directive,
  //                      sealed = __seal_owned_<owner>(gep); RAUW gep -> sealed
  //                      (restoring the accessor's own arg).
  unsigned EmbeddedAccessorsExported = 0;
  unsigned EmbeddedSealSites = 0;
  {
    // Role A: export accessors for owners that we are.
    std::set<std::string> OwnersToExport;
    for (auto &efs : Config.EmbeddedForeignSeals)
      if (efs.FieldOwner == ModName)
        OwnersToExport.insert(efs.FieldOwner);
    for (auto &Owner : OwnersToExport) {
      getOrCreateSealOwnedAccessor(M, Owner, SealcapGV);
      EmbeddedAccessorsExported++;
    }

    // Role B: rewrite derivation sites in this consumer module. Build a lookup
    // of (normalized container, normalized field type) -> field owner.
    std::map<std::pair<std::string, std::string>, std::string> ConsumerDirectives;
    for (auto &efs : Config.EmbeddedForeignSeals)
      if (efs.Consumer == ModName)
        ConsumerDirectives[{normEmbeddedName(efs.ContainerType),
                            normEmbeddedName(efs.FieldType)}] = efs.FieldOwner;

    if (!ConsumerDirectives.empty()) {
      // Collect matching GEPs first (do not mutate while iterating).
      std::vector<std::pair<GetElementPtrInst *, std::string>> Sites;
      for (Function &F : M) {
        if (F.isDeclaration())
          continue;
        for (Instruction &I : instructions(F)) {
          MDNode *MD = I.getMetadata("seal.embedded_field");
          if (!MD || MD->getNumOperands() < 2)
            continue;
          auto *GEP = dyn_cast<GetElementPtrInst>(&I);
          if (!GEP)
            continue;
          auto *ContMD = dyn_cast<MDString>(MD->getOperand(0).get());
          auto *FieldMD = dyn_cast<MDString>(MD->getOperand(1).get());
          if (!ContMD || !FieldMD)
            continue;
          auto It = ConsumerDirectives.find(
              {normEmbeddedName(ContMD->getString()),
               normEmbeddedName(FieldMD->getString())});
          if (It == ConsumerDirectives.end())
            continue;
          Sites.push_back({GEP, It->second});
        }
      }
      for (auto &Site : Sites) {
        GetElementPtrInst *GEP = Site.first;
        FunctionCallee Acc = getSealOwnedAccessorDecl(M, Site.second);
        IRBuilder<> B(GEP->getNextNode());
        CallInst *Sealed = B.CreateCall(Acc, {GEP}, "embedded.sealed");
        GEP->replaceAllUsesWith(Sealed);
        Sealed->setArgOperand(0, GEP);  // restore accessor's own input
        EmbeddedSealSites++;
      }
    }
  }
  if (EmbeddedAccessorsExported || EmbeddedSealSites) {
    Modified = true;
    errs() << "seal-instrument: embedded-foreign-field: exported "
           << EmbeddedAccessorsExported << " accessor(s), sealed "
           << EmbeddedSealSites << " derivation site(s)\n";
  }

  // ---- Strategy 1: Seal/unseal at call sites to external functions ----
  //
  // Deduplicate: keep only one entry per (callee, arg_index) pair.
  std::map<std::string, std::vector<const SealPoint*>> CalleePointMap;
  std::set<std::pair<std::string, int>> SeenCalleeArgs;
  for (auto &sp : Config.SealPoints) {
    if (sp.Action == "seal_before_call" || sp.Action == "unseal_after_call"
        || sp.Action == "receive_sealed" || sp.Action == "passthrough") {
      if (!sp.CalleeFunc.empty() && sp.CallerLib == ModName) {
        auto key = std::make_pair(sp.CalleeFunc, sp.ArgIndex);
        if (sp.Action == "seal_before_call" || sp.Action == "unseal_after_call") {
          if (SeenCalleeArgs.count(key))
            continue;
          SeenCalleeArgs.insert(key);
        }
        CalleePointMap[sp.CalleeFunc].push_back(&sp);
      }
    }
  }

  for (auto &F : M) {
    if (F.isDeclaration())
      continue;

    for (auto &BB : F) {
      for (auto &I : BB) {
        auto *CI = dyn_cast<CallInst>(&I);
        if (!CI) continue;

        Function *Callee = CI->getCalledFunction();
        if (!Callee) continue;

        std::string CalleeName = Callee->getName().str();
        auto it = CalleePointMap.find(CalleeName);
        if (it == CalleePointMap.end()) continue;

        for (auto *sp : it->second) {
          if (sp->Action == "seal_before_call" && sp->ArgIndex >= 0
              && sp->ArgIndex < (int)CI->arg_size()) {
            Value *Arg = CI->getArgOperand(sp->ArgIndex);
            if (!Arg->getType()->isPointerTy()) continue;

            // Verify the actual argument type at this call site.
            // The config entry identifies (callee, arg_index) pairs that
            // *sometimes* carry a sealable type, but different call sites
            // may pass different types to the same parameter (especially
            // void* parameters like libevent's event_set arg 4).  We
            // resolve the type from caller-side debug info and only seal
            // if this specific call site passes an owned sealable type.
            std::string actualType = resolveArgType(Arg);
            if (actualType.empty()) continue;
            if (!OwnedSealableTypes.count(actualType)) continue;

            // Seal the argument before passing to external function
            IRBuilder<> Builder(CI);
            Value *Sealed = emitSeal(Builder, M, Arg, SealcapGV);
            CI->setArgOperand(sp->ArgIndex, Sealed);
            SealCount++;
            SealBeforeCallCount++;
            Modified = true;
          }

          if (sp->Action == "unseal_after_call" && sp->ArgIndex == -1) {
            if (!CI->getType()->isPointerTy()) continue;

            // Verify the actual return type at THIS call site, mirroring the
            // seal_before_call arg-type check above (and Strategy 5b for
            // indirect calls).  The config entry marks (callee, -1) as
            // *sometimes* returning an owned sealable type, but different call
            // sites cast the same void* return to different types.  E.g.
            // SSL_CTX_get_ex_data is cast to ngx_shm_zone_s* in
            // ngx_ssl_new_session (nginx-owned → unseal) but to X509* in
            // ngx_ssl_session_cache (openssl-owned → must NOT unseal: doing so
            // unseals a pointer sealed with openssl's otype, clearing its tag
            // and aborting in __seal_assert_tag).  Only unseal when this site
            // returns a type we own; otherwise it is effectively receive_sealed.
            std::string actualRetType = resolveCallReturnType(CI, M);
            if (actualRetType.empty()) continue;
            if (!OwnedSealableTypes.count(actualRetType)) continue;

            // Unseal the return value from external function
            // Use guarded unseal: the return value might not be sealed
            // (e.g., if the callee is not instrumented yet)
            IRBuilder<> AfterBuilder(CI->getNextNode());
            Value *Unsealed = emitGuardedUnseal(
                AfterBuilder, M, CI, SealcapGV, CI->getFunction());
            // Replace only pre-existing uses (not the ones inside the guard)
            replaceUsesExceptGuard(CI, Unsealed);
            UnsealCount++;
            UnsealAfterCallCount++;
            Modified = true;
          }
        }
      }
    }
  }

  // ---- Helpers for D2 allocator exception ----

  // Returns the GlobalVariable that an indirect callee is loaded from (through
  // a single load, optionally via a GEP), or nullptr if not traceable.
  auto getCalleeSourceGlobal = [](const Value *V) -> const GlobalVariable * {
    const auto *LI = dyn_cast<LoadInst>(V);
    if (!LI) return nullptr;
    const Value *Ptr = LI->getPointerOperand()->stripPointerCasts();
    if (const auto *GV = dyn_cast<GlobalVariable>(Ptr))
      return GV;
    // Handle load through a struct field (GEP → global)
    if (const auto *GEP = dyn_cast<GetElementPtrInst>(Ptr))
      return dyn_cast<GlobalVariable>(
          GEP->getPointerOperand()->stripPointerCasts());
    return nullptr;
  };

  // Returns true if V (stripped of casts) is a known libc allocator function.
  auto isAllocatorFunction = [](const Value *V) -> bool {
    static const StringSet<> Allocators = {
        "free", "malloc", "calloc", "realloc", "reallocf"};
    const auto *F = dyn_cast<Function>(V->stripPointerCasts());
    return F && Allocators.count(F->getName());
  };

  // Returns true if the indirect callee can target a libc allocator — i.e.,
  // the global it is loaded from is initialised with or ever stored a known
  // allocator function.  Such call sites must not be sealed by D2 because
  // libc's allocator cannot handle sealed capabilities.
  auto calleeMayTargetAllocator = [&](const Value *Callee) -> bool {
    const GlobalVariable *GV = getCalleeSourceGlobal(Callee);
    if (!GV) return false;
    if (GV->hasInitializer() && isAllocatorFunction(GV->getInitializer()))
      return true;
    for (const User *U : GV->users())
      if (const auto *SI = dyn_cast<StoreInst>(U))
        if (isAllocatorFunction(SI->getValueOperand()))
          return true;
    return false;
  };

  // ---- Strategy D2: Seal owned args before indirect cross-compartment calls ----
  //
  // D1 (Strategy 1 above) handles direct calls to known external functions via
  // seal_before_call entries in the instrumentation config.  Those entries are
  // keyed by callee function name, so they cannot cover indirect calls (function
  // pointers, vtable dispatch, callbacks) where getCalledFunction() returns null.
  //
  // The analysis pipeline (CrossCompartmentTypeAnalyzer) also skips indirect
  // calls for the same reason — it resolves argument types only for direct
  // calls to declared external functions (analyzeExternalCalls, line 895).
  //
  // To close this gap, we resolve argument types locally from debug info
  // (resolveArgType, same approach the analyzer uses) and check each argument
  // against the set of sealable types owned by this module.  If an argument
  // is an owned sealable type, we emit a *guarded* seal: the argument is
  // only sealed if the function pointer's code base address differs from
  // this compartment's code base (__compartment_code_base, derived from PCC
  // at init time).  This avoids unnecessary sealing for intra-compartment
  // indirect calls (e.g., OpenSSL METHOD vtable dispatch within libssl)
  // while correctly sealing cross-compartment calls (e.g., OpenSSL invoking
  // an nginx-registered callback).
  {
    if (!OwnedSealableTypes.empty()) {
      // Group by CallInst: for each indirect call, collect all arg indices
      // that need sealing.  This lets us compute the cross-compartment check
      // once per call site and seal all args under a single guard.
      struct IndirectCallD2Info {
        CallInst *CI;
        std::vector<unsigned> ArgIndices;
      };
      std::vector<IndirectCallD2Info> D2Calls;
      std::map<CallInst *, size_t> CallToIdx; // CI → index in D2Calls

      // COLLECTION PHASE: find indirect calls with owned sealable arg types
      for (auto &F : M) {
        if (F.isDeclaration()) continue;
        for (auto &BB : F) {
          for (auto &I : BB) {
            auto *CI = dyn_cast<CallInst>(&I);
            if (!CI) continue;
            if (CI->getCalledFunction() != nullptr) continue; // direct — handled by D1
            if (calleeMayTargetAllocator(CI->getCalledOperand())) continue;

            for (unsigned i = 0; i < CI->arg_size(); i++) {
              Value *Arg = CI->getArgOperand(i);
              if (!Arg->getType()->isPointerTy()) continue;
              std::string ArgType = resolveArgType(Arg);
              if (ArgType.empty()) continue;
              if (!OwnedSealableTypes.count(ArgType)) continue;

              errs() << "seal-instrument D2: in " << F.getName()
                     << " indirect call arg " << i
                     << " type=" << ArgType << "\n";

              auto it = CallToIdx.find(CI);
              if (it == CallToIdx.end()) {
                CallToIdx[CI] = D2Calls.size();
                D2Calls.push_back({CI, {i}});
              } else {
                D2Calls[it->second].ArgIndices.push_back(i);
              }
            }
          }
        }
      }

      // INSTRUMENTATION PHASE: one cross-compartment check per call site,
      // then seal all owned args under that single guard.
      for (auto &D2 : D2Calls) {
        IRBuilder<> Builder(D2.CI);
        Value *IsExt = emitIsExternalCall(Builder, M,
            D2.CI->getCalledOperand(), CodeBaseGV);

        for (unsigned ArgIdx : D2.ArgIndices) {
          Value *Sealed = emitGuardedSeal(Builder, M,
              D2.CI->getArgOperand(ArgIdx), IsExt, SealcapGV,
              D2.CI->getFunction());
          D2.CI->setArgOperand(ArgIdx, Sealed);
          SealCount++;
          SealD2Count++;
          Modified = true;
        }
      }

      if (SealD2Count > 0) {
        errs() << "seal-instrument: " << SealD2Count
               << " indirect call arg seals (Strategy D2) across "
               << D2Calls.size() << " call sites\n";
      }
    }
  }

  // ---- Strategy 2: Unseal on entry to owner's exported functions ----

  for (auto &sp : Config.SealPoints) {
    if (sp.Action != "unseal_on_entry") continue;
    if (ModName != sp.Owner && sp.Owner != "unknown")
      continue;

    Function *F = M.getFunction(sp.CalleeFunc);
    if (!F || F->isDeclaration()) continue;
    if (sp.ArgIndex < 0 || sp.ArgIndex >= (int)F->arg_size()) continue;

    Argument *Arg = F->getArg(sp.ArgIndex);
    if (!Arg->getType()->isPointerTy()) continue;

    IRBuilder<> Builder(&*F->getEntryBlock().getFirstInsertionPt());
    // Use guarded unseal: the function may be called internally (with
    // unsealed pointers) or externally (with sealed pointers).
    // Unconditional unseal of an unsealed pointer clears the tag.
    Value *Unsealed = emitGuardedUnseal(Builder, M, Arg, SealcapGV, F);
    // Replace only pre-existing uses (not the ones inside the guard)
    replaceUsesExceptGuard(Arg, Unsealed);
    UnsealCount++;
    UnsealOnEntryCount++;
    Modified = true;
  }

  // ---- Strategy 4: Seal on return from owning library functions ----

  std::map<std::string, int> ReturnSealMap;

  // Populate ReturnSealMap from explicit seal_on_return entries only.
  // These are generated by seal_codegen.py from the callee's own return
  // type analysis (analyzeReturnType in CrossCompartmentTypeAnalyzer).
  // The callee determines whether to seal its return — never inferred
  // from caller-side information (receive_sealed).
  for (auto &sp : Config.SealPoints) {
    if (sp.Action != "seal_on_return") continue;
    if (sp.CalleeFunc.empty()) continue;
    std::string owner = sp.Owner;
    if (owner.empty() || owner == "unknown") continue;
    if (owner != ModName) continue;
    if (ReturnSealMap.find(sp.CalleeFunc) == ReturnSealMap.end())
      ReturnSealMap[sp.CalleeFunc] = sp.TypeId;
  }

  errs() << "seal-instrument: " << ReturnSealMap.size()
         << " functions identified for seal-on-return\n";

  for (auto &[FuncName, TypeId] : ReturnSealMap) {
    Function *F = M.getFunction(FuncName);
    if (!F || F->isDeclaration()) continue;
    if (!F->getReturnType()->isPointerTy()) continue;

    // Collect return instructions first to avoid iterator invalidation
    // from block splitting in emitGuardedSeal.
    SmallVector<ReturnInst *, 8> Returns;
    for (auto &BB : *F) {
      if (auto *RI = dyn_cast<ReturnInst>(BB.getTerminator())) {
        Value *RetVal = RI->getReturnValue();
        if (!RetVal) continue;
        if (!RetVal->getType()->isPointerTy()) continue;
        if (isa<ConstantPointerNull>(RetVal)) continue;
        Returns.push_back(RI);
      }
    }
    for (auto *RI : Returns) {
      Value *RetVal = RI->getReturnValue();
      IRBuilder<> Builder(RI);
      Value *Sealed = emitGuardedSeal(Builder, M, RetVal, SealcapGV, F);
      RI->setOperand(0, Sealed);
      SealOnReturnCount++;
      SealCount++;
      Modified = true;
    }
  }

  // ---- Strategy 5: Unseal after calling own exported function ----
  //
  // When a function in this module calls another function in the same module
  // that has seal-on-return (Strategy 4), the caller gets back a sealed
  // pointer.  Since the caller is in the same library, it needs to unseal
  // the return value to use it.  Use guarded unseal so this also works if
  // the callee is ever inlined or called via a path that skips the seal.

  for (auto &[FuncName, TypeId] : ReturnSealMap) {
    Function *Callee = M.getFunction(FuncName);
    if (!Callee || Callee->isDeclaration()) continue;
    if (!Callee->getReturnType()->isPointerTy()) continue;

    for (auto &F : M) {
      if (F.isDeclaration()) continue;
      if (&F == Callee) continue;  // skip self-recursive calls

      for (auto &BB : F) {
        for (auto &I : BB) {
          auto *CI = dyn_cast<CallInst>(&I);
          if (!CI) continue;
          if (CI->getCalledFunction() != Callee) continue;
          if (!CI->getType()->isPointerTy()) continue;

          IRBuilder<> Builder(CI->getNextNode());
          Value *Unsealed = emitGuardedUnseal(
              Builder, M, CI, SealcapGV, CI->getFunction());
          replaceUsesExceptGuard(CI, Unsealed);
          UnsealCount++;
          UnsealStrategy5Count++;
          Modified = true;
        }
      }
    }
  }

  // ---- Strategy 5b: Unseal after indirect calls returning owned types ----
  //
  // Strategy 5 handles direct calls to known functions in the ReturnSealMap.
  // But indirect calls (function pointers, vtable dispatch) can also resolve
  // to these functions at runtime.  CI->getCalledFunction() returns null for
  // indirect calls, so Strategy 5 misses them entirely.
  //
  // Fix: for each indirect call in this module that returns a pointer, resolve
  // the return type from debug info.  If the type is sealable and owned by
  // this module, insert a guarded unseal.  The guard (cheri_is_sealed check)
  // makes this safe even if the actual callee doesn't have seal_on_return —
  // the unseal is simply skipped for unsealed pointers.
  {
    unsigned IndirectUnsealCount = 0;
    // OwnedSealableTypes already built above (shared by D1, D2, and 5b)

    if (!OwnedSealableTypes.empty()) {
      // Collect indirect calls first, then instrument (avoids iterator invalidation)
      struct IndirectCallInfo {
        CallInst *CI;
        std::string TypeName;
      };
      std::vector<IndirectCallInfo> IndirectCalls;

      for (auto &F : M) {
        if (F.isDeclaration()) continue;
        for (auto &BB : F) {
          for (auto &I : BB) {
            auto *CI = dyn_cast<CallInst>(&I);
            if (!CI) continue;
            if (CI->getCalledFunction() != nullptr) continue;  // direct call — handled by Strategy 5
            if (!CI->getType()->isPointerTy()) continue;

            std::string RetType = resolveCallReturnType(CI, M);
            if (RetType.empty()) continue;
            if (!OwnedSealableTypes.count(RetType)) continue;

            IndirectCalls.push_back({CI, RetType});
          }
        }
      }

      for (auto &IC : IndirectCalls) {
        IRBuilder<> Builder(IC.CI->getNextNode());
        Value *Unsealed = emitGuardedUnseal(
            Builder, M, IC.CI, SealcapGV, IC.CI->getFunction());
        replaceUsesExceptGuard(IC.CI, Unsealed);
        IndirectUnsealCount++;
        UnsealCount++;
        UnsealStrategy5bCount++;
        Modified = true;
      }

      if (IndirectUnsealCount > 0) {
        errs() << "seal-instrument: " << IndirectUnsealCount
               << " indirect call unseals (Strategy 5b)\n";
      }
    }
  }

  // ---- Strategy 3a: Generate accessor function bodies (owner side) ----
  //
  // For each type this module owns that needs accessors, synthesize
  // getter (and setter) functions in IR.  These are callable by non-owner
  // modules that link against this library.
  //
  // Generated function:
  //   define <field_type> @cheri_accessor_<type>_get_<field>(ptr %sealed) {
  //     %sealcap = load ptr, ptr @__sealcap
  //     %raw = call ptr @llvm.cheri.cap.unseal(ptr %sealed, ptr %sealcap)
  //     %fptr = getelementptr %struct.T, ptr %raw, i32 0, i32 <field_idx>
  //     %val = load <field_type>, ptr %fptr
  //     ret <field_type> %val
  //   }

  for (auto &typeInfo : Config.Types) {
    if (typeInfo.Owner != ModName) continue;
    if (!typeInfo.NeedsAccessor) continue;
    // Never generate an accessor for an anonymous type (defense-in-depth;
    // seal_codegen.py already excludes these). Its name collides across
    // unrelated structs, and the fuzzy suffix match below would spray it
    // over every struct.anon.NNN in the module.
    if (isAnonymousStructName(typeInfo.TypeName)) continue;

    auto catIt = Config.StructCatalog.find(typeInfo.TypeName);
    if (catIt == Config.StructCatalog.end()) {
      errs() << "seal-instrument: no struct_catalog entry for "
             << typeInfo.TypeName << ", skipping accessor generation\n";
      continue;
    }

    // Find the struct type in the module.
    // llvm-link may rename duplicate struct types by appending a numeric
    // suffix (e.g. struct.ossl_param_st.269).  Try exact match first,
    // then fall back to prefix match with suffix stripping.
    StructType *STy = nullptr;
    for (auto *ST : M.getIdentifiedStructTypes()) {
      if (!ST->hasName()) continue;
      if (ST->getName() == typeInfo.TypeName) {
        STy = ST;
        break;
      }
    }
    if (!STy) {
      // Fuzzy match: look for "<TypeName>.<digits>"
      std::string prefix = typeInfo.TypeName + ".";
      std::vector<StructType *> candidates;
      for (auto *ST : M.getIdentifiedStructTypes()) {
        if (!ST->hasName()) continue;
        StringRef sn = ST->getName();
        if (sn.startswith(prefix)) {
          StringRef suffix = sn.drop_front(prefix.size());
          bool allDigits = !suffix.empty();
          for (char c : suffix)
            if (!isdigit(c)) { allDigits = false; break; }
          if (allDigits)
            candidates.push_back(ST);
        }
      }
      if (!candidates.empty()) {
        STy = candidates[0];
        // Verify all suffixed variants have the same layout
        for (size_t ci = 1; ci < candidates.size(); ci++) {
          if (candidates[ci]->getNumElements() != STy->getNumElements()) {
            errs() << "seal-instrument WARNING: conflicting struct definitions for "
                   << typeInfo.TypeName << ": "
                   << STy->getName() << " has " << STy->getNumElements()
                   << " fields, " << candidates[ci]->getName() << " has "
                   << candidates[ci]->getNumElements() << " fields\n";
          }
        }
        errs() << "seal-instrument: using " << STy->getName()
               << " for " << typeInfo.TypeName
               << " (suffix match, " << candidates.size() << " variant(s))\n";
      }
    }
    if (!STy) {
      errs() << "seal-instrument: struct type " << typeInfo.TypeName
             << " not found in module, skipping accessor generation\n";
      continue;
    }

    std::string typeCName = typeInfo.CName;

    for (auto &field : catIt->second.Fields) {
      if (field.Index < 0 || (unsigned)field.Index >= STy->getNumElements())
        continue;

      Type *FieldTy = STy->getElementType(field.Index);
      bool IsArrayField = FieldTy->isArrayTy();

      // For array fields (e.g. char label[32]), the getter returns a
      // pointer to the array — you can't return an array by value.
      // For scalar fields, the getter returns the value directly.
      Type *GetterRetTy = IsArrayField ? PtrTy : FieldTy;

      // ---- Getter ----
      std::string getterName = "cheri_accessor_" + typeCName +
                               "_get_" + field.Name;

      // Skip if function already exists (e.g. from a previous pass run)
      if (M.getFunction(getterName)) continue;

      auto *GetterFTy = FunctionType::get(GetterRetTy, {PtrTy}, false);
      auto *GetterFn = Function::Create(
          GetterFTy, GlobalValue::ExternalLinkage, AS, getterName, &M);
      GetterFn->setCallingConv(CallingConv::C);
      GetterFn->getArg(0)->setName("sealed");

      auto *GetterBB = BasicBlock::Create(M.getContext(), "entry", GetterFn);
      IRBuilder<> GB(GetterBB);

      Value *Sealed = GetterFn->getArg(0);
      Value *Raw = emitUnseal(GB, M, Sealed, SealcapGV);
      Value *FieldPtr = GB.CreateStructGEP(STy, Raw, field.Index,
                                            "field." + field.Name);

      if (IsArrayField) {
        // Return pointer to the array field
        GB.CreateRet(FieldPtr);
      } else {
        // Return the loaded scalar value
        Value *Val = GB.CreateLoad(FieldTy, FieldPtr, "val");
        GB.CreateRet(Val);
      }

      AccessorCount++;
      Modified = true;
      errs() << "seal-instrument: generated getter " << getterName << "\n";

      // ---- Setter ----
      // Skip setters for array fields — can't pass arrays by value.
      // Array field modification would need a memcpy-based accessor.
      if (IsArrayField) continue;

      std::string setterName = "cheri_accessor_" + typeCName +
                               "_set_" + field.Name;

      if (M.getFunction(setterName)) continue;

      auto *SetterFTy = FunctionType::get(
          Type::getVoidTy(M.getContext()), {PtrTy, FieldTy}, false);
      auto *SetterFn = Function::Create(
          SetterFTy, GlobalValue::ExternalLinkage, AS, setterName, &M);
      SetterFn->setCallingConv(CallingConv::C);
      SetterFn->getArg(0)->setName("sealed");
      SetterFn->getArg(1)->setName("val");

      auto *SetterBB = BasicBlock::Create(M.getContext(), "entry", SetterFn);
      IRBuilder<> SB(SetterBB);

      Value *SSealed = SetterFn->getArg(0);
      Value *SRaw = emitUnseal(SB, M, SSealed, SealcapGV);
      Value *SFieldPtr = SB.CreateStructGEP(STy, SRaw, field.Index,
                                             "field." + field.Name);
      SB.CreateStore(SetterFn->getArg(1), SFieldPtr);
      SB.CreateRetVoid();

      errs() << "seal-instrument: generated setter " << setterName << "\n";
    }
  }

  // ---- Strategy 3b: Replace field accesses with accessor calls ----
  //       (non-owner side, driven by !seal.field_access metadata)
  //
  // The analysis pass tagged GEP/load/store instructions with metadata:
  //   !seal.field_access !{ !"struct.foo_data", i32 <field_index> }
  //
  // For each tagged instruction in a non-owner module, replace:
  //   - GEP + load  → getter call
  //   - GEP + store → setter call
  //   - direct load (field 0) → getter call
  //   - direct store (field 0) → setter call

  {
    // Build a lookup: type_name -> field_index -> field_name
    std::map<std::string, std::map<int, std::string>> FieldNameLookup;
    for (auto &[tname, cat] : Config.StructCatalog) {
      for (auto &f : cat.Fields)
        FieldNameLookup[tname][f.Index] = f.Name;
    }

    // Collect instructions to replace (can't modify while iterating)
    struct ReplacementInfo {
      Instruction *Inst;
      std::string TypeName;
      int FieldIdx;
      std::string FieldName;
      std::string TypeCName;
    };
    std::vector<ReplacementInfo> Replacements;

    for (auto &F : M) {
      if (F.isDeclaration()) continue;

      for (auto &BB : F) {
        for (auto &I : BB) {
          MDNode *MD = I.getMetadata("seal.field_access");
          if (!MD || MD->getNumOperands() < 2) continue;

          auto *TypeMD = dyn_cast<MDString>(MD->getOperand(0));
          auto *IdxMD = dyn_cast<ConstantAsMetadata>(MD->getOperand(1));
          if (!TypeMD || !IdxMD) continue;

          std::string TypeName = TypeMD->getString().str();
          int FieldIdx = cast<ConstantInt>(IdxMD->getValue())->getSExtValue();

          // Never rewrite an access to an anonymous type into an accessor call
          // (defense-in-depth): its name collides across unrelated structs, so
          // the "owner" and its accessor may belong to a different compartment
          // than this pointer (the memcached cq->head STAILQ abort).
          if (isAnonymousStructName(TypeName)) continue;

          // Only replace in non-owner modules
          auto ownerIt = Config.TypeNameToOwner.find(TypeName);
          if (ownerIt == Config.TypeNameToOwner.end()) continue;
          if (ownerIt->second == ModName) continue;  // owner keeps direct access

          // Check needs_accessor flag
          bool needsAccessor = false;
          for (auto &t : Config.Types) {
            if (t.TypeName == TypeName && t.NeedsAccessor) {
              needsAccessor = true;
              break;
            }
          }
          if (!needsAccessor) continue;

          // Look up field name
          auto fnIt = FieldNameLookup.find(TypeName);
          if (fnIt == FieldNameLookup.end()) continue;
          auto fieldIt = fnIt->second.find(FieldIdx);
          if (fieldIt == fnIt->second.end()) continue;

          std::string typeCName = TypeName;
          if (typeCName.substr(0, 7) == "struct.")
            typeCName = typeCName.substr(7);

          Replacements.push_back({&I, TypeName, FieldIdx,
                                  fieldIt->second, typeCName});
        }
      }
    }

    // Apply replacements
    for (auto &R : Replacements) {
      if (auto *GEP = dyn_cast<GetElementPtrInst>(R.Inst)) {
        // GEP-based access (field 1+, or field 0 with explicit GEP)
        Value *BasePtr = GEP->getPointerOperand();

        // Skip stack-allocated structs: if the base pointer is an alloca,
        // the struct was constructed locally by this compartment — it's not
        // a sealed pointer received from the owner, so accessor calls would
        // crash trying to unseal it.
        if (isa<AllocaInst>(BasePtr->stripPointerCasts()))
          continue;

        // Check if the field is an array type — if so, the getter returns
        // a pointer (the GEP result is used as a pointer, not loaded).
        Type *SrcElemTy = GEP->getSourceElementType();
        auto *SrcSTy = dyn_cast<StructType>(SrcElemTy);
        bool FieldIsArray = SrcSTy &&
            (unsigned)R.FieldIdx < SrcSTy->getNumElements() &&
            SrcSTy->getElementType(R.FieldIdx)->isArrayTy();

        if (FieldIsArray) {
          // Array field: GEP result is used as a pointer (e.g. passed to
          // printf, strcmp).  Replace GEP with getter call that returns ptr.
          std::string getterName = "cheri_accessor_" + R.TypeCName +
                                   "_get_" + R.FieldName;
          auto *GetterFTy = FunctionType::get(PtrTy, {PtrTy}, false);
          FunctionCallee GetterFn =
              M.getOrInsertFunction(getterName, GetterFTy);

          IRBuilder<> Builder(GEP);
          Value *Result = Builder.CreateCall(
              GetterFn, {BasePtr}, "accessor_" + R.FieldName);
          GEP->replaceAllUsesWith(Result);
          GEP->eraseFromParent();
          AccessorCount++;
          Modified = true;
        } else {
          // Scalar field: find loads and stores that use this GEP
          std::vector<Instruction*> ToErase;

          for (auto *U : GEP->users()) {
            if (auto *LI = dyn_cast<LoadInst>(U)) {
              // Replace GEP + load with getter call
              std::string getterName = "cheri_accessor_" + R.TypeCName +
                                       "_get_" + R.FieldName;
              Type *LoadTy = LI->getType();
              auto *GetterFTy = FunctionType::get(LoadTy, {PtrTy}, false);
              FunctionCallee GetterFn =
                  M.getOrInsertFunction(getterName, GetterFTy);

              IRBuilder<> Builder(LI);
              Value *Result = Builder.CreateCall(
                  GetterFn, {BasePtr}, "accessor_" + R.FieldName);
              LI->replaceAllUsesWith(Result);
              ToErase.push_back(LI);
              AccessorCount++;
              Modified = true;
            } else if (auto *SI = dyn_cast<StoreInst>(U)) {
              if (SI->getPointerOperand() == GEP) {
                // Replace GEP + store with setter call
                std::string setterName = "cheri_accessor_" + R.TypeCName +
                                         "_set_" + R.FieldName;
                Type *ValTy = SI->getValueOperand()->getType();
                auto *SetterFTy = FunctionType::get(
                    Type::getVoidTy(M.getContext()), {PtrTy, ValTy}, false);
                FunctionCallee SetterFn =
                    M.getOrInsertFunction(setterName, SetterFTy);

                IRBuilder<> Builder(SI);
                Builder.CreateCall(
                    SetterFn, {BasePtr, SI->getValueOperand()});
                ToErase.push_back(SI);
                AccessorCount++;
                Modified = true;
              }
            }
          }

          for (auto *E : ToErase)
            E->eraseFromParent();
          if (GEP->use_empty())
            GEP->eraseFromParent();
        }

      } else if (auto *LI = dyn_cast<LoadInst>(R.Inst)) {
        // Direct load (field 0) — replace with getter call
        Value *BasePtr = LI->getPointerOperand();
        if (isa<AllocaInst>(BasePtr->stripPointerCasts()))
          continue;
        std::string getterName = "cheri_accessor_" + R.TypeCName +
                                 "_get_" + R.FieldName;
        Type *LoadTy = LI->getType();
        auto *GetterFTy = FunctionType::get(LoadTy, {PtrTy}, false);
        FunctionCallee GetterFn =
            M.getOrInsertFunction(getterName, GetterFTy);

        IRBuilder<> Builder(LI);
        Value *Result = Builder.CreateCall(
            GetterFn, {BasePtr}, "accessor_" + R.FieldName);
        LI->replaceAllUsesWith(Result);
        LI->eraseFromParent();
        AccessorCount++;
        Modified = true;

      } else if (auto *SI = dyn_cast<StoreInst>(R.Inst)) {
        // Direct store (field 0) — replace with setter call
        Value *BasePtr = SI->getPointerOperand();
        if (isa<AllocaInst>(BasePtr->stripPointerCasts()))
          continue;
        std::string setterName = "cheri_accessor_" + R.TypeCName +
                                 "_set_" + R.FieldName;
        Type *ValTy = SI->getValueOperand()->getType();
        auto *SetterFTy = FunctionType::get(
            Type::getVoidTy(M.getContext()), {PtrTy, ValTy}, false);
        FunctionCallee SetterFn =
            M.getOrInsertFunction(setterName, SetterFTy);

        IRBuilder<> Builder(SI);
        Builder.CreateCall(SetterFn, {BasePtr, SI->getValueOperand()});
        SI->eraseFromParent();
        AccessorCount++;
        Modified = true;
      }
    }
  }

  // ---- Register __seal_init() as an ELF constructor (.init_array) ----
  //
  // Using @llvm.global_ctors ensures __seal_init() is called by the dynamic
  // linker when the .so is loaded (or early in main for executables).
  // This works for both executables AND shared libraries, unlike the previous
  // approach of inserting a call into main() which left @__sealcap null in
  // shared libraries.
  //
  // Priority 101 ensures it runs before default-priority (65535) constructors
  // that might pass sealed pointers across compartments.
  {
    auto *I32Ty = Type::getInt32Ty(M.getContext());
    auto *CtorStructTy = StructType::get(
        I32Ty, InitFn->getType(), PtrTy);

    Constant *CtorEntry = ConstantStruct::get(CtorStructTy, {
        ConstantInt::get(I32Ty, 101),             // priority
        InitFn,                                    // constructor function
        ConstantPointerNull::get(PtrTy)            // associated data (unused)
    });

    auto *CtorArrayTy = ArrayType::get(CtorStructTy, 1);
    auto *NewCtors = new GlobalVariable(
        M, CtorArrayTy, false, GlobalValue::AppendingLinkage,
        ConstantArray::get(CtorArrayTy, {CtorEntry}),
        "llvm.global_ctors");
    (void)NewCtors;

    errs() << "seal-instrument: registered __seal_init() as .init_array "
           << "constructor (priority 101)\n";
  }

  errs() << "seal-instrument: " << SealCount << " seal insertions ("
         << SealOnReturnCount << " seal-on-return, "
         << SealBeforeCallCount << " seal-before-call, "
         << SealD2Count << " indirect-call-D2), "
         << UnsealCount << " unseal insertions ("
         << UnsealOnEntryCount << " on-entry, "
         << UnsealStrategy5Count << " strategy-5, "
         << UnsealStrategy5bCount << " strategy-5b, "
         << UnsealAfterCallCount << " after-call), "
         << AccessorCount << " accessor replacements\n";

  return Modified;
}

} // anonymous namespace

// ============================================================================
// New Pass Manager: PassInfoMixin-based module pass (LLVM 15+)
// ============================================================================
namespace {

struct SealInstrumentationPass
    : public PassInfoMixin<SealInstrumentationPass> {

  PreservedAnalyses run(Module &M, ModuleAnalysisManager & /*AM*/) {
    if (SealConfigFile.empty()) {
      errs() << "seal-instrument: no -seal-config specified, skipping\n";
      return PreservedAnalyses::all();
    }

    InstrumentationConfig Config;
    if (!Config.load(SealConfigFile)) {
      errs() << "seal-instrument: failed to load config, skipping\n";
      return PreservedAnalyses::all();
    }

    bool Changed = instrumentModule(M, Config);
    return Changed ? PreservedAnalyses::none() : PreservedAnalyses::all();
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
      LLVM_PLUGIN_API_VERSION, "SealInstrumentationPass", "0.1",
      [](PassBuilder &PB) {
        PB.registerPipelineParsingCallback(
            [](StringRef Name, ModulePassManager &MPM,
               ArrayRef<PassBuilder::PipelineElement>) {
              if (Name == "seal-instrument") {
                MPM.addPass(SealInstrumentationPass());
                return true;
              }
              return false;
            });
      }};
}
