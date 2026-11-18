#!/usr/bin/env python3
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

"""
seal_codegen.py — Generate CHERI sealing instrumentation from analysis results

Reads the cross-compartment analysis JSON report (and optionally per-library
type manifests) to produce an instrumentation config JSON consumed by the
SealInstrumentationPass LLVM pass.

Usage (report-only mode — no manifests needed):
    python3 seal_codegen.py \
        --report reports/nginx/nginx_cross_compartment_report.json \
        --output-dir generated/

Usage (with manifests for richer instrumentation data):
    python3 seal_codegen.py \
        --report reports/nginx/nginx_cross_compartment_report.json \
        --manifests workspace/nginx/output/manifests/*.json \
        --output-dir generated/
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple


# ========================= System types to exclude =========================

SYSTEM_TYPES: Set[str] = {
    "struct.__va_list_tag",
    "struct.addrinfo",
    "struct.dirent",
    "struct.stat",
    "struct.tm",
    "struct.timespec",
    "struct.timeval",
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
    "struct.sockaddr",
    "struct.sockaddr_in",
    "struct.sockaddr_in6",
    "struct.sockaddr_un",
    "struct.sockaddr_storage",
    "struct.msghdr",
    "struct.cmsghdr",
    "struct.pollfd",
    "struct.epoll_event",
    "struct.servent",
    "struct.kevent",
    "struct._IO_FILE",
    "struct.__sFILE",
    "struct.__dirstream",
    "struct.pthread_once",
    "struct.pthread_mutex",
    "struct.pthread_cond",
    "struct.pthread_attr",
}


def sanitize_type_name(llvm_type: str) -> str:
    """Convert LLVM struct name to a valid C identifier.

    E.g. 'struct.X509_crl_st' -> 'X509_crl_st'
    """
    name = llvm_type
    if name.startswith("struct."):
        name = name[len("struct."):]
    name = re.sub(r"[^a-zA-Z0-9_]", "_", name)
    return name


def is_anonymous_struct(type_name: str) -> bool:
    """True for anonymous / compiler-placeholder struct names that cannot be
    soundly attributed to a single compartment.

    clang names anonymous C structs (e.g. the sys/queue.h STAILQ_HEAD /
    TAILQ_HEAD bodies used pervasively) 'struct.anon', 'struct.anon.0',
    'struct.anon.1', ...  These are DISTINCT, unrelated types that merely share
    a placeholder name; under LTO they collapse onto the same name. Treating
    'struct.anon' as one shared cross-compartment type is therefore unsound:
    one compartment's anonymous struct gets an accessor owned by another
    (observed: memcached's cq->head STAILQ write rewritten to libevent's
    cheri_accessor_anon_set_field_1, which unseals a pointer memcached never
    sealed -> abort). Exclude them, like system/unknown-owner types.
    """
    name = type_name
    for prefix in ("struct.", "union."):
        if name.startswith(prefix):
            name = name[len(prefix):]
            break
    # Bare 'anon', numeric-suffixed 'anon.269' (clang / LTO rename), or empty.
    if name in ("", "anon") or name.startswith("anon."):
        return True
    if type_name == "<anonymous-struct>":
        return True
    return False


def load_report(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def load_manifests(paths: List[str]) -> Dict[str, dict]:
    """Load per-library manifests, keyed by library name."""
    manifests = {}
    for p in paths:
        with open(p) as f:
            text = f.read()
        # Strip LLVM pass output surrounding the JSON payload
        begin_marker = "===CROSS_COMPARTMENT_JSON_BEGIN==="
        end_marker = "===CROSS_COMPARTMENT_JSON_END==="
        if begin_marker in text:
            start = text.index(begin_marker) + len(begin_marker)
            end = text.index(end_marker)
            text = text[start:end].strip()
        data = json.loads(text)
        module_path = data.get("module", p)
        lib_name = Path(module_path).stem
        if lib_name.endswith("_manifest"):
            lib_name = Path(p).stem.replace("_manifest", "_merged")
        manifests[lib_name] = data
    return manifests


def generate_type_ids(
    report: dict,
) -> Tuple[Dict[str, int], List[dict]]:
    """Assign numeric type IDs to each sealable type (excluding system types).

    Returns (type_id_map, sealable_types_info)
    """
    type_id_map: Dict[str, int] = {}
    sealable_types: List[dict] = []
    next_id = 0

    for shared in report.get("shared_types", []):
        type_name = shared["type"]
        owner = shared.get("owner", "unknown")

        # Skip system types and types with no determinable owner.
        # Unknown-owner types cannot be sealed because no library can
        # generate unseal_on_entry for them (see docs/TODO.md #1).
        # Also skip anonymous structs: their placeholder name ('struct.anon')
        # collides across unrelated types/compartments, so attributing one to
        # a single owner (and generating an accessor for it) is unsound.
        if (owner in ("system", "unknown")
                or type_name in SYSTEM_TYPES
                or is_anonymous_struct(type_name)):
            continue

        should_seal = False
        needs_accessor = False
        has_address_taken = False
        for entry in shared.get("shared_with", []):
            rec = entry.get("sealing_recommendation", "")
            if rec == "seal":
                should_seal = True
            elif rec == "needs_accessor":
                needs_accessor = True
            elif rec == "cannot_seal":
                # Non-owner accesses ALL fields — sealing with full-access
                # accessors adds overhead with no security benefit. Skip.
                pass
            elif rec == "address_taken":
                # Non-owner takes address of a field (&struct->field).
                # Cannot seal without subobject bounds support.
                has_address_taken = True

        if has_address_taken:
            continue

        if not should_seal and not needs_accessor:
            continue

        type_id_map[type_name] = next_id
        sealable_types.append(
            {
                "type_id": next_id,
                "type_name": type_name,
                "c_name": sanitize_type_name(type_name),
                "owner": owner,
                "total_fields": shared.get("total_fields", 0),
                "needs_accessor": needs_accessor,
                "shared_with": shared.get("shared_with", []),
            }
        )
        next_id += 1

    return type_id_map, sealable_types


def build_instrumentation_config_from_report(
    sealable_types: List[dict],
    libraries: List[str],
) -> dict:
    """Build instrumentation config using only the cross-compartment report.

    The report's shared_with[].access_functions tells us which functions in
    each non-owner library touch each type.  From the owner's side, we know
    that exported functions accepting the type must unseal on entry and
    seal on return.
    """
    type_id_for = {t["type_name"]: t["type_id"] for t in sealable_types}
    owner_for = {t["type_name"]: t["owner"] for t in sealable_types}

    seal_points = []

    for stype in sealable_types:
        type_name = stype["type_name"]
        type_id = stype["type_id"]
        owner = stype["owner"]

        for entry in stype.get("shared_with", []):
            lib = entry.get("library", "")
            rec = entry.get("sealing_recommendation", "")
            access_fns = entry.get("access_functions", [])

            if rec == "seal":
                # This library holds the pointer opaquely.
                # Every function in this library that touches this type
                # receives it sealed and passes it sealed — no action needed
                # within the library itself.  But the boundary calls need
                # seal/unseal.
                for fn in access_fns:
                    seal_points.append(
                        {
                            "library": lib,
                            "function": fn,
                            "type_name": type_name,
                            "type_id": type_id,
                            "owner": owner,
                            "action": "opaque_holder",
                        }
                    )

            elif rec == "needs_accessor":
                # This library accesses specific fields — it must use
                # accessor functions instead of direct GEP.
                for fn in access_fns:
                    seal_points.append(
                        {
                            "library": lib,
                            "function": fn,
                            "type_name": type_name,
                            "type_id": type_id,
                            "owner": owner,
                            "fields_accessed": entry.get(
                                "fields_accessed", []
                            ),
                            "field_indices": entry.get("field_indices", []),
                            "action": "replace_with_accessor",
                        }
                    )

    return {
        "num_types": len(sealable_types),
        "libraries": libraries,
        "types": [
            {
                "type_id": t["type_id"],
                "type_name": t["type_name"],
                "c_name": t["c_name"],
                "owner": t["owner"],
                "needs_accessor": t["needs_accessor"],
            }
            for t in sealable_types
        ],
        "seal_points": seal_points,
    }


def build_instrumentation_config_from_manifests(
    sealable_types: List[dict],
    manifests: Dict[str, dict],
    struct_catalog: Optional[Dict[str, dict]] = None,
) -> dict:
    """Build richer instrumentation config using per-library manifests.

    This mode provides exact call-site information: which caller function
    calls which external callee with which sealable type arguments.
    """
    sealable_set = {t["type_name"] for t in sealable_types}
    type_id_for = {t["type_name"]: t["type_id"] for t in sealable_types}
    owner_for = {t["type_name"]: t["owner"] for t in sealable_types}

    seal_points = []

    # Build the set of functions defined in analyzed libraries.
    # Calls to functions NOT in this set are to system/libc functions
    # (e.g. strlen, memcmp, free) which run in the same address space
    # and must dereference their arguments — sealing would break them.
    analyzed_funcs: Set[str] = set()
    for manifest in manifests.values():
        for func_info in manifest.get("defined_functions", []):
            analyzed_funcs.add(func_info["name"])

    # Build callee param type index: function_name -> {param_idx: type_name}
    # Same logic as cross_compartment_analyzer.build_call_graph(): prefer
    # the callee's declared param type over the caller's debug info.
    callee_param_types: Dict[str, Dict[int, str]] = {}
    for manifest in manifests.values():
        for func_info in manifest.get("defined_functions", []):
            if not func_info.get("externally_visible", False):
                continue
            fname = func_info["name"]
            if fname not in callee_param_types:
                callee_param_types[fname] = {}
            for idx_str, type_names in func_info.get(
                "param_struct_types", {}
            ).items():
                if type_names:
                    # type_names is a list; take the first
                    callee_param_types[fname][int(idx_str)] = type_names[0]

    for lib_name, manifest in manifests.items():
        for func_info in manifest.get("defined_functions", []):
            caller_func = func_info["name"]

            for ext_call in func_info.get("external_calls", []):
                callee = ext_call.get("callee", "")
                if not callee:
                    continue

                # Only seal/unseal at compartment boundaries — calls to
                # functions defined in one of the analyzed libraries.
                # System functions (libc, POSIX) need raw pointer access.
                is_compartment_boundary = callee in analyzed_funcs

                # Resolve arg types: prefer callee's param types over
                # caller's debug info (see lesson learned #12).
                caller_arg_types = ext_call.get("arg_struct_types", [])
                callee_params = callee_param_types.get(callee, {})
                resolved_arg_types = []
                for idx, caller_type in enumerate(caller_arg_types):
                    callee_type = callee_params.get(idx, None)
                    if callee_type:
                        resolved_arg_types.append(callee_type)
                    else:
                        resolved_arg_types.append(caller_type)

                for arg_idx, arg_type in enumerate(resolved_arg_types):
                    if arg_type and arg_type in sealable_set:
                        owner = owner_for[arg_type]
                        if not is_compartment_boundary:
                            # System function — no sealing
                            continue
                        if lib_name == owner or owner == "unknown":
                            action = "seal_before_call"
                        else:
                            action = "passthrough"

                        seal_points.append(
                            {
                                "caller_lib": lib_name,
                                "caller_func": caller_func,
                                "callee_func": callee,
                                "arg_index": arg_idx,
                                "type_name": arg_type,
                                "type_id": type_id_for[arg_type],
                                "owner": owner,
                                "action": action,
                            }
                        )

                ret_type = ext_call.get("return_struct_type")
                if ret_type and ret_type in sealable_set:
                    owner = owner_for[ret_type]
                    if not is_compartment_boundary:
                        # System function — no sealing
                        continue
                    if lib_name == owner:
                        # Caller owns the return type — it was sealed with
                        # the caller's otype (scenario 7), so the caller
                        # can unseal it when it comes back.
                        action = "unseal_after_call"
                    else:
                        # Callee owns the return type (or unknown) — it was
                        # sealed with the callee's otype (scenario 3).
                        # Caller can't unseal (wrong key) — scenario 8.
                        action = "receive_sealed"

                    seal_points.append(
                        {
                            "caller_lib": lib_name,
                            "caller_func": caller_func,
                            "callee_func": callee,
                            "arg_index": -1,
                            "type_name": ret_type,
                            "type_id": type_id_for[ret_type],
                            "owner": owner,
                            "action": action,
                        }
                    )

    # Unseal on entry for owner's externally visible functions
    for stype in sealable_types:
        owner = stype["owner"]
        type_name = stype["type_name"]
        if owner == "unknown":
            continue

        owner_manifest = manifests.get(owner)
        if not owner_manifest:
            continue

        for func_info in owner_manifest.get("defined_functions", []):
            if not func_info.get("externally_visible", False):
                continue
            param_types = func_info.get("param_struct_types", {})
            for param_idx_str, types_list in param_types.items():
                if type_name in types_list:
                    seal_points.append(
                        {
                            "caller_lib": "__external__",
                            "callee_func": func_info["name"],
                            "callee_lib": owner,
                            "arg_index": int(param_idx_str),
                            "type_name": type_name,
                            "type_id": stype["type_id"],
                            "owner": owner,
                            "action": "unseal_on_entry",
                        }
                    )

    # Seal on return for owner's externally visible functions.
    # Uses the callee's own return_struct_type (from body analysis) to
    # determine what to seal — independent of consumer manifests.
    for lib_name, manifest in manifests.items():
        for func_info in manifest.get("defined_functions", []):
            if not func_info.get("externally_visible", False):
                continue
            ret_type = func_info.get("return_struct_type")
            if not ret_type or ret_type not in sealable_set:
                continue
            owner = owner_for.get(ret_type)
            if owner != lib_name:
                continue  # only seal if this lib owns the return type
            seal_points.append(
                {
                    "callee_func": func_info["name"],
                    "callee_lib": lib_name,
                    "arg_index": -1,
                    "type_name": ret_type,
                    "type_id": type_id_for[ret_type],
                    "owner": owner,
                    "action": "seal_on_return",
                }
            )

    # Accessor replacements for non-owner field accesses
    for stype in sealable_types:
        if not stype.get("needs_accessor"):
            continue
        for entry in stype.get("shared_with", []):
            rec = entry.get("sealing_recommendation", "")
            if rec != "needs_accessor":
                continue
            lib = entry.get("library", "")
            if not lib or lib not in manifests:
                continue
            for fn in entry.get("access_functions", []):
                seal_points.append(
                    {
                        "caller_lib": lib,
                        "caller_func": fn,
                        "type_name": stype["type_name"],
                        "type_id": stype["type_id"],
                        "owner": stype["owner"],
                        "fields_accessed": entry.get(
                            "fields_accessed", []
                        ),
                        "field_indices": entry.get("field_indices", []),
                        "action": "replace_with_accessor",
                    }
                )

    # Build struct_catalog subset for sealable types that need accessors.
    # The LLVM pass uses this to generate accessor function bodies in IR.
    catalog_for_config = {}
    if struct_catalog:
        for stype in sealable_types:
            if not stype.get("needs_accessor"):
                continue
            tname = stype["type_name"]
            if tname in struct_catalog:
                catalog_for_config[tname] = {
                    "fields": struct_catalog[tname].get("fields", []),
                    "owner": stype["owner"],
                }

    return {
        "num_types": len(sealable_types),
        "libraries": list(manifests.keys()),
        "types": [
            {
                "type_id": t["type_id"],
                "type_name": t["type_name"],
                "c_name": t["c_name"],
                "owner": t["owner"],
                "needs_accessor": t["needs_accessor"],
            }
            for t in sealable_types
        ],
        "seal_points": seal_points,
        "struct_catalog": catalog_for_config,
    }


def build_embedded_foreign_seals(
    report: dict,
    sealable_types: List[dict],
) -> List[dict]:
    """Resolve embedded-foreign-field candidates (from the report) into concrete
    seal directives — THE decision point, because only here do we know both the
    ownership (from the report) AND the final, post-exclusion sealable set.

    A candidate is kept only if its FIELD TYPE is in the final sealable set —
    i.e. the field's owner actually seals it (emits unseal_on_entry / accessors),
    so a sealed capability is exactly what every downstream consumer expects.
    Candidates whose field type was excluded from sealing
    (system/unknown/anonymous/cannot_seal/address_taken) are dropped: sealing
    them would produce a capability nobody unseals.

    Additive and independent of types/seal_points/struct_catalog. Distinct from
    the existing 'address_taken' path (that is a non-owner taking the address of
    a field of a FOREIGN container; this is a LOCAL container embedding a foreign
    field by value).
    """
    sealable_by_name = {t["type_name"]: t for t in sealable_types}
    directives: List[dict] = []
    for cand in report.get("embedded_foreign_fields", []):
        field_type = cand.get("field_type", "")
        st = sealable_by_name.get(field_type)
        if st is None:
            # Field type is not in the final sealable set -> owner won't unseal
            # it; skip rather than emit an inconsistent seal.
            continue
        # Defensive: the sealable set's owner is authoritative.
        if cand.get("field_owner") and cand["field_owner"] != st["owner"]:
            continue
        directives.append({
            "container_type": cand["container_type"],
            "consumer": cand["consumer"],
            "field_type": field_type,
            "field_owner": st["owner"],
            "field_type_id": st["type_id"],
            "field_index": cand["field_index"],
            "function": cand["function"],
        })
    return directives


def main():
    parser = argparse.ArgumentParser(
        description="Generate CHERI sealing instrumentation code"
    )
    parser.add_argument(
        "--report",
        required=True,
        help="Path to cross_compartment_report.json",
    )
    parser.add_argument(
        "--manifests",
        nargs="+",
        default=None,
        help="Paths to per-library manifest JSON files (optional)",
    )
    parser.add_argument(
        "--output-dir",
        required=True,
        help="Output directory for generated files",
    )
    parser.add_argument(
        "--embedded-foreign-seals",
        action="store_true",
        help="Emit the embedded_foreign_seals section (opt-in; off by default). "
             "Covers a locally-owned struct that embeds a foreign-owned struct "
             "BY VALUE whose address is taken, e.g. curl's zlib_writer.z_stream. "
             "Must be paired with -seal-embedded-fields on the LLVM pass.",
    )
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    report = load_report(args.report)
    libraries = report.get("libraries", [])

    manifests = None
    struct_catalog = None
    if args.manifests:
        manifests = load_manifests(args.manifests)
        # Build struct catalog for accessor field type resolution
        struct_catalog = {}
        for lib_name, manifest in manifests.items():
            for struct in manifest.get("struct_catalog", []):
                sname = struct["name"]
                new_fields = struct.get("fields", [])
                if sname not in struct_catalog:
                    struct_catalog[sname] = {
                        "fields": new_fields,
                        "total_size": struct.get("total_size", 0),
                        "source_lib": lib_name,
                    }
                else:
                    # Prefer the entry with actual field names (from the
                    # defining library) over one with only indices.
                    old_fields = struct_catalog[sname].get("fields", [])
                    old_has_names = any(f.get("name") for f in old_fields)
                    new_has_names = any(f.get("name") for f in new_fields)
                    if (new_has_names and not old_has_names) or \
                       (len(new_fields) > len(old_fields)):
                        struct_catalog[sname] = {
                            "fields": new_fields,
                            "total_size": struct.get("total_size", 0),
                            "source_lib": lib_name,
                        }
        print(f"Loaded {len(manifests)} library manifests")
        print(f"Struct catalog: {len(struct_catalog)} types")
    else:
        print("Running in report-only mode (no per-library manifests)")

    # Assign type IDs
    type_id_map, sealable_types = generate_type_ids(report)
    print(f"Sealable types: {len(sealable_types)}")
    accessor_count = sum(1 for t in sealable_types if t["needs_accessor"])
    print(f"  - Pure seal: {len(sealable_types) - accessor_count}")
    print(f"  - Needs accessor: {accessor_count}")

    # Build instrumentation config
    if manifests:
        instr_config = build_instrumentation_config_from_manifests(
            sealable_types, manifests, struct_catalog
        )
    else:
        instr_config = build_instrumentation_config_from_report(
            sealable_types, libraries
        )
    print(f"Seal points: {len(instr_config['seal_points'])}")

    # Opt-in path: resolve embedded-foreign-field candidates into concrete seal
    # directives, gated on the field type being in the final sealable set.
    # Additive — leaves types/seal_points/struct_catalog untouched.
    # The key is always emitted so the config schema does not vary; when the
    # flag is off it is simply empty, which the pass treats as "nothing to do".
    if args.embedded_foreign_seals:
        instr_config["embedded_foreign_seals"] = build_embedded_foreign_seals(
            report, sealable_types
        )
        print(f"Embedded foreign seals: "
              f"{len(instr_config['embedded_foreign_seals'])}")
    else:
        instr_config["embedded_foreign_seals"] = []
        n_cand = len(report.get("embedded_foreign_fields", []))
        print(f"Embedded foreign seals: disabled "
              f"(--embedded-foreign-seals not given; {n_cand} candidate(s) "
              f"in the report left unresolved)")

    # Write instrumentation config
    config_path = os.path.join(args.output_dir, "instrumentation_config.json")
    with open(config_path, "w") as f:
        json.dump(instr_config, f, indent=2)
    print(f"Wrote {config_path}")

    # Summary
    print("\n=== Summary ===")
    for stype in sealable_types:
        tag = "ACCESSOR" if stype["needs_accessor"] else "SEAL"
        print(
            f"  [{tag}] {stype['type_name']} "
            f"(id={stype['type_id']}, owner={stype['owner']})"
        )

    action_counts: Dict[str, int] = defaultdict(int)
    for sp in instr_config["seal_points"]:
        action_counts[sp["action"]] += 1
    print("\nSeal point actions:")
    for action, count in sorted(action_counts.items()):
        print(f"  {action}: {count}")


if __name__ == "__main__":
    main()
