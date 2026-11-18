#!/usr/bin/env python3
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

"""
cross_compartment_analyzer.py — Cross-compartment type sharing analysis

Takes per-library type usage manifests (JSON output from the
CrossCompartmentTypeAnalyzer LLVM pass) and cross-references them to
determine:
  - Which struct types are shared across library compartment boundaries
  - Which fields each library accesses (or holds opaquely)
  - Sealing recommendations for CHERI compartmentalization

Usage:
    python3 cross_compartment_analyzer.py \
        --manifests lib1_manifest.json lib2_manifest.json prog_manifest.json \
        --output report.json \
        [--program-name nginx]
"""
from __future__ import annotations
import argparse
import json
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple


# ========================= System / libc Type Registry =========================
# Types defined by the C standard library, POSIX, or the compiler runtime.
# These don't belong to any analyzed library — they are owned by "system".

_SYSTEM_TYPE_NAMES: Set[str] = {
    # C standard library
    "struct.tm",
    "struct.timespec",
    "struct.timeval",
    "struct.stat",
    "struct.dirent",
    "struct.iovec",
    "struct.utsname",
    "struct.passwd",
    "struct.group",
    "struct.sigaction",
    "struct.sigevent",
    "struct.rusage",
    "struct.rlimit",
    "struct.flock",
    "struct.termios",
    "struct.statvfs",
    "struct.sched_param",
    # Networking (POSIX)
    "struct.sockaddr",
    "struct.sockaddr_in",
    "struct.sockaddr_in6",
    "struct.sockaddr_un",
    "struct.sockaddr_storage",
    "struct.addrinfo",
    "struct.msghdr",
    "struct.cmsghdr",
    "struct.linger",
    "struct.pollfd",
    "struct.epoll_event",
    "struct.in_addr",
    "struct.in6_addr",
    "struct.hostent",
    "struct.servent",
    "struct.ifaddrs",
    "struct.ip_mreq",
    # Compiler / ABI
    "struct.__va_list_tag",
    "struct.__jmp_buf_tag",
    # FILE I/O
    "struct._IO_FILE",
    "struct._IO_marker",
    "struct.__sFILE",          # FreeBSD/CheriBSD FILE
    # Threads (POSIX)
    "struct.pthread_once",
    "struct.pthread_mutex",
    "struct.pthread_cond",
    "struct.pthread_attr",
}


def is_system_type(type_name: str) -> bool:
    """Check whether a struct type is a well-known system/libc type."""
    return type_name in _SYSTEM_TYPE_NAMES


# LLVM names every anonymous struct or union "struct.anon"/"union.anon", with a
# numeric suffix to keep them apart WITHIN a module. Across modules the names
# carry no meaning at all: in the memcached compartment set, libevent's
# struct.anon is a 32-byte pair of pointers while OpenSSL's is 1296 bytes over
# 36 fields. Since sharing is decided by matching type names across
# compartments, treating these as identities fuses unrelated types.
_ANON_TYPE_RE = re.compile(r"^(?:struct|union)\.anon(?:\.|$)")


def is_anonymous_type(type_name: str) -> bool:
    """Check whether a type name is LLVM's placeholder for an anonymous type.

    Such a name is only unique within its own module, so it must never be used
    to conclude that two compartments share a type.
    """
    return bool(_ANON_TYPE_RE.match(type_name))


# ========================= Data Structures =========================

@dataclass
class FieldInfo:
    index: int
    type_str: str
    offset: int
    size: int
    name: str = ""  # from debug info, may be empty


@dataclass
class StructInfo:
    name: str
    total_size: int
    fields: List[FieldInfo]

    def field_name(self, idx: int) -> str:
        """Get human-readable field name (debug name or fallback to index)."""
        for f in self.fields:
            if f.index == idx:
                return f.name if f.name else f"field_{idx}"
        return f"field_{idx}"


@dataclass
class FunctionInfo:
    name: str
    externally_visible: bool
    struct_field_accesses: Dict[str, Set[int]]  # struct name -> field indices
    address_taken_fields: Dict[str, Set[int]]   # struct name -> field indices (address-of)
    # param index -> struct names, in the order the analyzer pass emitted them.
    # A list, not a set: the order is load-bearing (see _parse_function).
    param_struct_types: Dict[int, List[str]]
    external_calls: List[dict]                  # raw call info
    return_struct_type: Optional[str] = None    # struct type returned (from body analysis)
    # NEW (embedded-foreign-field): container struct -> {field idx -> embedded
    # struct type name}, for by-value embedded members whose address is taken.
    embedded_struct_fields: Dict[str, Dict[int, str]] = field(default_factory=dict)


@dataclass
class TypeManifest:
    module_name: str
    struct_catalog: Dict[str, StructInfo]       # struct name -> info
    defined_functions: List[FunctionInfo]
    types_in: List[dict]
    types_out: List[dict]


@dataclass
class LibraryAccess:
    library: str
    fields_accessed: List[str]          # human-readable field names
    field_indices: List[int]
    access_functions: List[str]
    opaque: bool
    sealing_recommendation: str         # "seal", "needs_accessor", "cannot_seal"


@dataclass
class SharedTypeInfo:
    type_name: str
    owner_library: str
    total_fields: int
    shared_with: List[LibraryAccess]


@dataclass
class SealingSummary:
    total_shared_types: int = 0
    sealable_opaque: int = 0
    needs_accessor: int = 0
    cannot_seal: int = 0
    address_taken: int = 0


# ========================= Manifest Loading =========================

def _parse_field(raw: dict) -> FieldInfo:
    return FieldInfo(
        index=raw["index"],
        type_str=raw["type"],
        offset=raw["offset"],
        size=raw["size"],
        name=raw.get("name", ""),
    )


def _parse_struct(raw: dict) -> StructInfo:
    return StructInfo(
        name=raw["name"],
        total_size=raw["total_size"],
        fields=[_parse_field(f) for f in raw.get("fields", [])],
    )


def _parse_function(raw: dict) -> FunctionInfo:
    sfa = {}
    for sname, indices in raw.get("struct_field_accesses", {}).items():
        sfa[sname] = set(indices)

    atf = {}
    for sname, indices in raw.get("address_taken_fields", {}).items():
        atf[sname] = set(indices)

    # Order-preserving de-duplication, NOT set(). A parameter often has several
    # candidate struct types (278 of them in OpenSSL alone), and build_call_graph
    # resolves the argument by taking the first. set() made "the first" depend on
    # string hashing, so PYTHONHASHSEED randomisation silently changed which type
    # was attributed to the argument — and hence which types counted as shared.
    # The manifest's list order is the pass's own deterministic emission order.
    pst = {}
    for param_idx_str, snames in raw.get("param_struct_types", {}).items():
        pst[int(param_idx_str)] = list(dict.fromkeys(snames))

    # NEW: embedded by-value struct members whose address is taken.
    # Manifest shape: { container: [ {"index": i, "field_type": "struct.T"} ] }
    esf: Dict[str, Dict[int, str]] = {}
    for sname, entries in raw.get("embedded_struct_fields", {}).items():
        esf[sname] = {int(e["index"]): e["field_type"] for e in entries}

    return FunctionInfo(
        name=raw["name"],
        externally_visible=raw.get("externally_visible", False),
        struct_field_accesses=sfa,
        address_taken_fields=atf,
        param_struct_types=pst,
        external_calls=raw.get("external_calls", []),
        return_struct_type=raw.get("return_struct_type"),
        embedded_struct_fields=esf,
    )


def load_manifest(path: Path) -> TypeManifest:
    """Load a type usage manifest JSON file (output from LLVM pass)."""
    text = path.read_text()

    # Extract JSON between delimiters if present
    begin_marker = "===CROSS_COMPARTMENT_JSON_BEGIN==="
    end_marker = "===CROSS_COMPARTMENT_JSON_END==="
    if begin_marker in text:
        start = text.index(begin_marker) + len(begin_marker)
        end = text.index(end_marker)
        text = text[start:end].strip()

    raw = json.loads(text)

    catalog = {}
    for s in raw.get("struct_catalog", []):
        info = _parse_struct(s)
        catalog[info.name] = info

    functions = [_parse_function(f) for f in raw.get("defined_functions", [])]

    tf = raw.get("type_flow", {})

    return TypeManifest(
        module_name=raw.get("module", path.stem),
        struct_catalog=catalog,
        defined_functions=functions,
        types_in=tf.get("types_in", []),
        types_out=tf.get("types_out", []),
    )


def load_manifests(paths: List[Path]) -> Dict[str, TypeManifest]:
    """Load all manifests, keyed by a short library name derived from module name."""
    manifests = {}
    for p in paths:
        m = load_manifest(p)
        # Derive a short name: strip path, .bc extension, etc.
        short_name = Path(m.module_name).stem
        # If the name has path separators, take the last component
        short_name = short_name.split("/")[-1]
        manifests[short_name] = m
    return manifests


# ========================= Call Graph Construction =========================

def build_call_graph(manifests: Dict[str, TypeManifest]
                     ) -> Dict[Tuple[str, str], List[dict]]:
    """Cross-reference external calls with defined functions.

    Returns a map: (caller_lib, callee_lib) -> list of edges, where each edge
    contains the function name and struct types flowing through it.

    When multiple libraries export the same function name, edges are created
    to all non-caller libraries (conservative — avoids missing real sharing).

    For argument types, the callee's param_struct_types (from its DISubprogram)
    take priority over the caller's arg_struct_types. The caller's debug info
    resolves to the variable's declared type, which may be a container struct
    rather than the actual value being passed (e.g., ssl->ctx resolves to
    ngx_ssl_s instead of ssl_ctx_st). The callee's function signature is the
    authoritative source.
    """
    # Build index: function_name -> set of libraries that define it
    func_to_libs: Dict[str, Set[str]] = defaultdict(set)
    for lib_name, manifest in manifests.items():
        for func in manifest.defined_functions:
            if func.externally_visible:
                func_to_libs[func.name].add(lib_name)

    # Build index: function_name -> {param_idx: struct type name}
    # from callee-side manifests (authoritative parameter types)
    callee_param_types: Dict[str, Dict[int, str]] = {}
    for lib_name, manifest in manifests.items():
        for func in manifest.defined_functions:
            if not func.externally_visible:
                continue
            if func.name not in callee_param_types:
                callee_param_types[func.name] = {}
            for idx, type_names in func.param_struct_types.items():
                if type_names:
                    # First in the pass's emission order. Typically there is only
                    # one; where there are several this pick must be stable, so
                    # param_struct_types is an ordered list rather than a set.
                    #
                    # Prefer a named type over an anonymous one. The candidates
                    # for a parameter often include both a container and a
                    # member of it — libevent's event_config_entry has an
                    # anonymous list-entry as its first field — and picking the
                    # anonymous member attributes the sharing to a name that
                    # means nothing outside this module (see is_anonymous_type).
                    named = [t for t in type_names if not is_anonymous_type(t)]
                    callee_param_types[func.name][idx] = (
                        named[0] if named else type_names[0])

    # Warn about collisions
    for fname, libs in func_to_libs.items():
        if len(libs) > 1:
            print(f"Warning: function '{fname}' exported by multiple libraries: "
                  f"{', '.join(sorted(libs))}. Creating edges to all.",
                  file=sys.stderr)

    # Scan external calls
    edges: Dict[Tuple[str, str], List[dict]] = defaultdict(list)
    for caller_lib, manifest in manifests.items():
        for func in manifest.defined_functions:
            for call in func.external_calls:
                callee_name = call.get("callee", "")
                if callee_name not in func_to_libs:
                    continue

                # Exclude caller's own library — the call is external,
                # so the target must be a different library
                target_libs = func_to_libs[callee_name] - {caller_lib}
                if not target_libs:
                    continue

                # Resolve argument types: prefer callee's param types
                # over caller's debug info (see lesson learned #12).
                caller_arg_types = call.get("arg_struct_types", [])
                callee_params = callee_param_types.get(callee_name, {})
                resolved_arg_types = []
                for idx, caller_type in enumerate(caller_arg_types):
                    callee_type = callee_params.get(idx, "")
                    if callee_type:
                        resolved_arg_types.append(callee_type)
                    else:
                        resolved_arg_types.append(caller_type)

                arg_types = [t for t in resolved_arg_types if t]
                ret_type = call.get("return_struct_type")

                # Keep full positional arg types for cross-library validation
                arg_types_full = resolved_arg_types

                for callee_lib in target_libs:
                    edges[(caller_lib, callee_lib)].append({
                        "function": callee_name,
                        "caller_function": func.name,
                        "arg_struct_types": arg_types,
                        "arg_struct_types_full": arg_types_full,
                        "return_struct_type": ret_type,
                    })

    return dict(edges)


def validate_cross_library_types(
    manifests: Dict[str, TypeManifest],
    call_graph: Dict[Tuple[str, str], List[dict]]
) -> List[dict]:
    """Cross-check caller's arg_struct_types against callee's param_struct_types.

    Detects mismatches where the caller inferred a different struct type for an
    argument than what the callee declares in its debug info. Such mismatches
    indicate analysis bugs (e.g., attributing a parent struct to a sub-field
    pointer).

    Returns a list of mismatches. Prints warnings but does not exit — many
    mismatches are expected at real API boundaries (wrapper structs, typedefs,
    first-field casts like OpenSSL's STACK_OF macros).
    """
    # Build index: function_name -> {param_idx: set of struct type names}
    param_types_index: Dict[str, Dict[int, Set[str]]] = {}
    for lib_name, manifest in manifests.items():
        for func in manifest.defined_functions:
            if func.name not in param_types_index:
                param_types_index[func.name] = {}
            for idx, type_names in func.param_struct_types.items():
                param_types_index[func.name][idx] = type_names

    mismatches = []
    for (caller_lib, callee_lib), edges in call_graph.items():
        for edge in edges:
            callee_name = edge["function"]
            caller_arg_types = edge.get("arg_struct_types_full", [])

            if callee_name not in param_types_index:
                continue
            callee_params = param_types_index[callee_name]

            for idx, caller_type in enumerate(caller_arg_types):
                if not caller_type:
                    continue
                callee_type_set = callee_params.get(idx, [])
                if not callee_type_set:
                    continue  # callee has no struct type for this param — OK
                if caller_type not in callee_type_set:
                    mismatches.append({
                        "caller_lib": caller_lib,
                        "callee_lib": callee_lib,
                        "caller_function": edge.get("caller_function", ""),
                        "callee_function": callee_name,
                        "arg_index": idx,
                        "caller_says": caller_type,
                        "callee_says": sorted(callee_type_set),
                    })

    if mismatches:
        print(f"\nWARNING: {len(mismatches)} cross-library argument type "
              f"mismatches detected.", file=sys.stderr)
        print("These may indicate wrapper structs, typedefs, or first-field "
              "casts at API boundaries.", file=sys.stderr)
        # Deduplicate by (caller_type, callee_type) for compact summary
        seen = set()
        for m in mismatches:
            key = (m["caller_says"], tuple(m["callee_says"]))
            if key not in seen:
                seen.add(key)
                print(f"  {m['caller_says']} -> {m['callee_says']} "
                      f"(e.g., {m['caller_function']}() -> "
                      f"{m['callee_function']}())", file=sys.stderr)

    return mismatches


# ========================= Type Ownership =========================

def determine_type_ownership(manifests: Dict[str, TypeManifest]
                             ) -> Dict[str, str]:
    """Determine which library 'owns' each struct type.

    Heuristics (in order):
    1. Library that has the most functions accessing fields of that type
    2. Library whose name matches the type prefix (e.g., 'struct.ngx_*' -> nginx)
    3. Library that has the type in its catalog with the most fields defined
    """
    # Count field-accessing functions per type per library
    type_access_count: Dict[str, Dict[str, int]] = defaultdict(
        lambda: defaultdict(int))

    for lib_name, manifest in manifests.items():
        for func in manifest.defined_functions:
            for sname, fields in func.struct_field_accesses.items():
                if fields:  # non-empty field access
                    type_access_count[sname][lib_name] += 1

    ownership: Dict[str, str] = {}

    # Collect all struct type names across all manifests
    all_types: Set[str] = set()
    for manifest in manifests.values():
        all_types.update(manifest.struct_catalog.keys())

    for type_name in all_types:
        # System/libc types are never owned by any analyzed library
        if is_system_type(type_name):
            ownership[type_name] = "system"
            continue

        counts = type_access_count.get(type_name, {})

        if counts:
            # Pick library with most accessing functions
            owner = max(counts, key=counts.get)
            ownership[type_name] = owner
        else:
            # Fallback: try name matching
            # Strip "struct." prefix for matching
            bare_name = type_name.removeprefix("struct.")
            best_match = ""
            best_lib = ""
            for lib_name in manifests:
                # Check if type name starts with a library-related prefix
                lib_prefix = lib_name.lower().replace("lib", "")
                if lib_prefix and bare_name.lower().startswith(lib_prefix):
                    if len(lib_prefix) > len(best_match):
                        best_match = lib_prefix
                        best_lib = lib_name
            if best_lib:
                ownership[type_name] = best_lib
            else:
                # Last resort: first library that has it in catalog
                for lib_name, manifest in manifests.items():
                    if type_name in manifest.struct_catalog:
                        ownership[type_name] = lib_name
                        break

    return ownership


# =============== Embedded-foreign-field detection (NEW path) ===============

def find_embedded_foreign_fields(
    manifests: Dict[str, TypeManifest],
    ownership: Dict[str, str],
) -> List[dict]:
    """Find by-value embedded struct members whose type is owned by a DIFFERENT
    compartment than their container.

    This is a distinct situation from the existing 'address_taken' handling:
      - address_taken: a non-owner takes &foreignStruct->field (container foreign)
      - here:          &localStruct.foreignField (container local/current, the
                       embedded field's TYPE is foreign)

    Structural facts (which struct embeds which by value, address-taken) come
    from the analyzer manifests (embedded_struct_fields). Ownership decides
    'foreign'. The final gate — is the field type actually in the sealable set
    (so its owner emits unseal_on_entry/accessors)? — is applied later in
    seal_codegen.py, which knows the post-exclusion sealable set. This function
    only produces candidates; it does not alter any existing recommendation.
    """
    results: List[dict] = []
    seen: Set[Tuple[str, str, int, str]] = set()

    for lib_name, manifest in manifests.items():
        for func in manifest.defined_functions:
            for container, idx_map in func.embedded_struct_fields.items():
                # Container must be local to this compartment (or unknown owner).
                container_owner = ownership.get(container, "unknown")
                if container_owner not in (lib_name, "unknown"):
                    continue
                for field_idx, field_type in idx_map.items():
                    field_owner = ownership.get(field_type, "unknown")
                    # Field type must be owned by a KNOWN, DIFFERENT compartment.
                    if field_owner in ("system", "unknown") or field_owner == lib_name:
                        continue
                    key = (lib_name, container, field_idx, field_type)
                    if key in seen:
                        continue
                    seen.add(key)
                    results.append({
                        "container_type": container,
                        "consumer": lib_name,
                        "field_type": field_type,
                        "field_owner": field_owner,
                        "field_index": field_idx,
                        "function": func.name,
                    })

    return results


# ========================= Sharing Analysis =========================

def analyze_sharing(
    manifests: Dict[str, TypeManifest],
    call_graph: Dict[Tuple[str, str], List[dict]],
    ownership: Dict[str, str],
) -> List[SharedTypeInfo]:
    """Analyze cross-compartment type sharing."""

    # Build a map: type_name -> set of libraries that use it
    type_to_libs: Dict[str, Set[str]] = defaultdict(set)

    # From call graph edges
    for (caller, callee), edges in call_graph.items():
        for edge in edges:
            for t in edge["arg_struct_types"]:
                type_to_libs[t].add(caller)
                type_to_libs[t].add(callee)
            if edge["return_struct_type"]:
                type_to_libs[edge["return_struct_type"]].add(caller)
                type_to_libs[edge["return_struct_type"]].add(callee)

    # From type_flow in manifests
    for lib_name, manifest in manifests.items():
        for entry in manifest.types_in:
            type_to_libs[entry["type"]].add(lib_name)
        for entry in manifest.types_out:
            type_to_libs[entry["type"]].add(lib_name)

    # Filter to types shared across 2+ libraries
    shared_types: List[SharedTypeInfo] = []

    for type_name, libs in sorted(type_to_libs.items()):
        if len(libs) < 2:
            continue

        owner = ownership.get(type_name, "unknown")

        # Find the struct info — prefer the owner's manifest (it has
        # the struct definition and thus real field names from debug info).
        struct_info: Optional[StructInfo] = None
        if owner in manifests and type_name in manifests[owner].struct_catalog:
            struct_info = manifests[owner].struct_catalog[type_name]
        else:
            for manifest in manifests.values():
                if type_name in manifest.struct_catalog:
                    struct_info = manifest.struct_catalog[type_name]
                    break

        total_fields = len(struct_info.fields) if struct_info else 0

        shared_with: List[LibraryAccess] = []
        for lib_name in sorted(libs):
            # Skip owner library — unless owner is "system", then all
            # analyzed libraries are non-owners and should be listed
            if owner != "system" and lib_name == owner:
                continue

            # Determine which fields this library accesses
            accessed_indices: Set[int] = set()
            access_functions: List[str] = []

            manifest = manifests[lib_name]
            for func in manifest.defined_functions:
                if type_name in func.struct_field_accesses:
                    indices = func.struct_field_accesses[type_name]
                    accessed_indices.update(indices)
                    if indices:
                        access_functions.append(func.name)

            # Resolve field names
            field_names = []
            if struct_info:
                field_names = [struct_info.field_name(i)
                               for i in sorted(accessed_indices)]

            is_opaque = len(accessed_indices) == 0

            # Check for address-taken fields (non-owner takes &struct->field).
            # Without subobject bounds, these types cannot be sealed.
            has_address_taken = False
            for func in manifest.defined_functions:
                if type_name in func.address_taken_fields:
                    has_address_taken = True
                    break

            # Sealing recommendation
            if is_opaque:
                recommendation = "seal"
            elif has_address_taken:
                recommendation = "address_taken"
            elif total_fields > 0 and len(accessed_indices) >= total_fields:
                recommendation = "cannot_seal"
            else:
                recommendation = "needs_accessor"

            shared_with.append(LibraryAccess(
                library=lib_name,
                fields_accessed=field_names,
                field_indices=sorted(accessed_indices),
                access_functions=access_functions,
                opaque=is_opaque,
                sealing_recommendation=recommendation,
            ))

        if shared_with:
            shared_types.append(SharedTypeInfo(
                type_name=type_name,
                owner_library=owner,
                total_fields=total_fields,
                shared_with=shared_with,
            ))

    return shared_types


def compute_sealing_summary(shared_types: List[SharedTypeInfo]) -> SealingSummary:
    """Summarize sealing recommendations across all shared types.

    System types (libc/POSIX structs) are excluded from the summary because
    they are not candidates for CHERI sealing — they are defined by the OS
    and shared across all compartments by design.
    """
    non_system = [st for st in shared_types if st.owner_library != "system"]
    summary = SealingSummary(total_shared_types=len(non_system))
    for st in non_system:
        # Use the "worst" recommendation across all sharing libraries
        recommendations = {sw.sealing_recommendation for sw in st.shared_with}
        if "address_taken" in recommendations:
            summary.address_taken += 1
        elif "cannot_seal" in recommendations:
            summary.cannot_seal += 1
        elif "needs_accessor" in recommendations:
            summary.needs_accessor += 1
        else:
            summary.sealable_opaque += 1
    return summary


# ========================= Report Generation =========================

def generate_report(
    program_name: str,
    manifests: Dict[str, TypeManifest],
    shared_types: List[SharedTypeInfo],
    summary: SealingSummary,
    embedded_foreign_fields: Optional[List[dict]] = None,
) -> dict:
    """Generate the final JSON report."""
    libraries = sorted(manifests.keys())

    report = {
        "program": program_name,
        "libraries": libraries,
        "shared_types": [],
        # NEW path (additive): by-value embedded members whose type is foreign.
        # Resolved to a concrete seal decision later, in seal_codegen.py.
        "embedded_foreign_fields": embedded_foreign_fields or [],
        "sealing_summary": {
            "total_shared_types": summary.total_shared_types,
            "sealable_opaque": summary.sealable_opaque,
            "needs_accessor": summary.needs_accessor,
            "cannot_seal": summary.cannot_seal,
            "address_taken": summary.address_taken,
        },
    }

    for st in shared_types:
        type_entry = {
            "type": st.type_name,
            "owner": st.owner_library,
            "total_fields": st.total_fields,
            "shared_with": [],
        }
        for sw in st.shared_with:
            type_entry["shared_with"].append({
                "library": sw.library,
                "fields_accessed": sw.fields_accessed,
                "field_indices": sw.field_indices,
                "access_functions": sw.access_functions,
                "opaque": sw.opaque,
                "sealing_recommendation": sw.sealing_recommendation,
            })
        report["shared_types"].append(type_entry)

    return report


def generate_markdown_summary(report: dict) -> str:
    """Generate a human-readable markdown summary."""
    lines = []
    lines.append(f"# Cross-Compartment Type Sharing Report: {report['program']}")
    lines.append("")
    lines.append(f"**Libraries analyzed:** {', '.join(report['libraries'])}")
    lines.append("")

    s = report["sealing_summary"]
    lines.append("## Sealing Summary")
    lines.append("")
    lines.append(f"| Metric | Count |")
    lines.append(f"|--------|-------|")
    lines.append(f"| Total shared types | {s['total_shared_types']} |")
    lines.append(f"| Sealable (opaque usage) | {s['sealable_opaque']} |")
    lines.append(f"| Needs accessor functions | {s['needs_accessor']} |")
    lines.append(f"| Address taken (needs subobject bounds) | {s['address_taken']} |")
    lines.append(f"| Cannot seal | {s['cannot_seal']} |")
    lines.append("")

    lines.append("## Shared Types Detail")
    lines.append("")

    for st in report["shared_types"]:
        lines.append(f"### `{st['type']}` (owner: {st['owner']})")
        lines.append("")
        lines.append(f"Total fields: {st['total_fields']}")
        lines.append("")

        for sw in st["shared_with"]:
            icon = {"seal": "SEAL", "needs_accessor": "ACCESSOR",
                    "cannot_seal": "NO-SEAL",
                    "address_taken": "ADDR-TAKEN"}
            rec = icon.get(sw["sealing_recommendation"],
                          sw["sealing_recommendation"])
            lines.append(f"- **{sw['library']}** [{rec}]")
            if sw["opaque"]:
                lines.append(f"  - Holds pointer opaquely (never dereferences)")
            else:
                fields = ", ".join(sw["fields_accessed"]) or \
                         ", ".join(str(i) for i in sw["field_indices"])
                lines.append(f"  - Fields accessed: {fields}")
                if sw["access_functions"]:
                    funcs = ", ".join(f"`{f}`" for f in sw["access_functions"])
                    lines.append(f"  - Via functions: {funcs}")
        lines.append("")

    return "\n".join(lines)


# ========================= Main =========================

def main():
    parser = argparse.ArgumentParser(
        description="Cross-compartment type sharing analysis for CHERI sealing")
    parser.add_argument("--manifests", nargs="+", required=True, type=Path,
                        help="Per-library JSON manifests from LLVM pass")
    parser.add_argument("--output", required=True, type=Path,
                        help="Output JSON report path")
    parser.add_argument("--program-name", default="program",
                        help="Name of the main program")
    parser.add_argument("--markdown", type=Path,
                        help="Optional: also write a markdown summary")
    args = parser.parse_args()

    # Load manifests
    manifests = load_manifests(args.manifests)
    print(f"Loaded {len(manifests)} manifests: {', '.join(manifests.keys())}",
          file=sys.stderr)

    # Build call graph
    call_graph = build_call_graph(manifests)
    total_edges = sum(len(v) for v in call_graph.values())
    print(f"Cross-compartment call edges: {total_edges}", file=sys.stderr)

    # Validate: cross-check caller arg types against callee param types
    mismatches = validate_cross_library_types(manifests, call_graph)
    if not mismatches:
        print("Cross-library type validation passed", file=sys.stderr)

    # Determine type ownership
    ownership = determine_type_ownership(manifests)
    print(f"Type ownership determined for {len(ownership)} types",
          file=sys.stderr)

    # Analyze sharing
    shared_types = analyze_sharing(manifests, call_graph, ownership)
    print(f"Shared types found: {len(shared_types)}", file=sys.stderr)

    # NEW path: embedded-foreign-field candidates (by-value foreign member,
    # address taken). Final sealable gate is applied in seal_codegen.py.
    embedded_foreign = find_embedded_foreign_fields(manifests, ownership)
    print(f"Embedded-foreign-field candidates: {len(embedded_foreign)}",
          file=sys.stderr)

    # Compute summary
    summary = compute_sealing_summary(shared_types)

    # Generate report
    report = generate_report(args.program_name, manifests, shared_types, summary,
                             embedded_foreign_fields=embedded_foreign)

    # Write JSON
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"JSON report written to {args.output}", file=sys.stderr)

    # Write markdown if requested
    md_path = args.markdown or args.output.with_suffix(".md")
    md_text = generate_markdown_summary(report)
    md_path.write_text(md_text)
    print(f"Markdown summary written to {md_path}", file=sys.stderr)

    # Print summary to stdout
    print(f"\n=== Sealing Summary ===")
    print(f"Total shared types:        {summary.total_shared_types}")
    print(f"  Sealable (opaque):       {summary.sealable_opaque}")
    print(f"  Needs accessor:          {summary.needs_accessor}")
    print(f"  Address taken:           {summary.address_taken}")
    print(f"  Cannot seal:             {summary.cannot_seal}")


if __name__ == "__main__":
    main()
