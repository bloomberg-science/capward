#!/usr/bin/env python3
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

"""gen_tables.py — regenerate the paper's sealing tables from pipeline output.

Reads, for each evaluated application, the artifacts that the capward
pipeline leaves in the workspace:

    workspace/<app>/generated/sealing_report.json   (steps 3-4: shared types)
    workspace/<app>/build/instrument_<lib>.log      (step 6: pass counters)

and emits three LaTeX tables:

    summary    cross-compartment sealing instrumentation summary
    accessors  struct types requiring accessor functions
    shared     representative shared struct types per app/library

Usage:
    python3 results/macrobenchmarks/scripts/gen_tables.py                 # all three
    python3 results/macrobenchmarks/scripts/gen_tables.py --table summary
    python3 results/macrobenchmarks/scripts/gen_tables.py --workspace /path/to/workspace
    python3 results/macrobenchmarks/scripts/gen_tables.py --include-unknown

Type-ownership filtering
    Types owned by "system" (libc/POSIX: sockaddr, tm, timeval, ...) are always
    excluded: they are shared by design and are not sealing candidates.
    Types whose owner could not be resolved ("unknown") are excluded by DEFAULT
    too. These are opaque struct declarations — SSL_SESSION, OCSP_RESPONSE,
    SSL_CIPHER and friends — whose definition never appears in any analysed
    module, so total_fields is 0 and no accessor can actually be generated for
    them. Counting them inflates both Shared and Acc. without corresponding to
    any emitted instrumentation. Pass --include-unknown to count them anyway
    (this reproduces the raw sealing_summary block in sealing_report.json).
"""

import argparse
import json
import os
import re
import sys

# Compartment layout per app; the first entry is the application itself.
APPS = {
    "nginx":     ["nginx", "openssl", "pcre2", "zlib"],
    "redis":     ["redis", "openssl"],
    "memcached": ["memcached", "openssl", "libevent"],
    "curl":      ["curl", "openssl", "zlib"],
    "wget":      ["wget", "openssl", "zlib"],
    "lighttpd":  ["lighttpd", "openssl", "zlib"],
}

# Display names for the owning compartment.
OWNER_LABEL = {
    "openssl_merged":  "OpenSSL",
    "zlib_merged":     "zlib",
    "pcre2_merged":    "PCRE2",
    "libevent_merged": "libevent",
}

# Whether an accessor for this type would hand back a pointer to another
# struct. Opaque pointers erase this in the IR — every pointer field is just
# `ptr addrspace(200)` — so it cannot be derived from the config and is
# curated here. Revisit if the analyzer starts recording DWARF pointee types.
STRUCT_PTR = {
    "struct.z_stream_s":      False,   # Bytef*/void*/fn-ptr fields, no struct ptr
    "struct.asn1_string_st":  False,   # data is unsigned char*
    "struct.ossl_param_st":   False,   # data is void*
    "struct.X509_info_st":    True,    # x509, crl -> X509*, X509_CRL*
    "struct.GENERAL_NAME_st": True,    # d is a union of struct pointers
}

# Short LaTeX names + footnote markers for the accessor table.
SHORT_NAME = {
    "struct.z_stream_s":      ("z\\_stream",  "z\\_stream\\_s"),
    "struct.asn1_string_st":  ("asn1\\_str",  "asn1\\_string\\_st"),
    "struct.X509_info_st":    ("X509\\_info", "X509\\_info\\_st"),
    "struct.ossl_param_st":   ("ossl\\_param", "ossl\\_param\\_st"),
    "struct.GENERAL_NAME_st": ("GENERAL\\_N", "GENERAL\\_NAME\\_st"),
}

COUNTER_RE = re.compile(
    r"(\d+)\s+(seal insertions|unseal insertions|accessor replacements)")


def tex(s):
    """Escape a C identifier for LaTeX \\texttt{}."""
    return s.replace("_", "\\_")


def strip_struct(name):
    return name[len("struct."):] if name.startswith("struct.") else name


def load(ws, app):
    p = os.path.join(ws, app, "generated", "sealing_report.json")
    if not os.path.exists(p):
        return None
    with open(p) as f:
        return json.load(f)


def counters(ws, app, libs):
    """Sum the pass counters across this app's compartments."""
    seal = unseal = acc = 0
    per_lib = {}
    for lib in libs:
        p = os.path.join(ws, app, "build", "instrument_%s.log" % lib)
        a = b = c = 0
        if os.path.exists(p):
            with open(p, errors="replace") as f:
                for line in f:
                    for n, what in COUNTER_RE.findall(line):
                        n = int(n)
                        if what == "seal insertions":
                            a += n
                        elif what == "unseal insertions":
                            b += n
                        else:
                            c += n
        per_lib[lib] = (a, b, c)
        seal += a
        unseal += b
        acc += c
    return seal, unseal, acc, per_lib


def keep(owner, include_unknown):
    if owner == "system":
        return False
    if owner == "unknown" and not include_unknown:
        return False
    return True


def classify(shared_with):
    """Worst-case recommendation across all non-owning compartments.

    address_taken and cannot_seal both mean 'not sealed', and the paper's
    NoSeal column covers both.
    """
    recs = {e.get("sealing_recommendation") for e in shared_with}
    if "address_taken" in recs or "cannot_seal" in recs:
        return "noseal"
    if "needs_accessor" in recs:
        return "accessor"
    return "seal"


def summarize(ws, include_unknown):
    rows = {}
    for app, libs in APPS.items():
        rep = load(ws, app)
        if rep is None:
            continue
        n_shared = n_seal = n_acc = n_no = 0
        for st in rep["shared_types"]:
            if not keep(st["owner"], include_unknown):
                continue
            n_shared += 1
            k = classify(st.get("shared_with", []))
            if k == "seal":
                n_seal += 1
            elif k == "accessor":
                n_acc += 1
            else:
                n_no += 1
        si, ui, ar, per_lib = counters(ws, app, libs)
        rows[app] = dict(cmp=len(libs), shared=n_shared, seal=n_seal,
                         acc=n_acc, noseal=n_no, si=si, ui=ui, ar=ar,
                         per_lib=per_lib)
    return rows


def table_summary(rows):
    out = []
    a = out.append
    a("% Table 1: Summary  (generated by results/macrobenchmarks/scripts/gen_tables.py)")
    a("\\begin{table}[t]")
    a("\\centering")
    a("\\setlength{\\tabcolsep}{3pt}")
    a("\\caption{Cross-compartment sealing instrumentation summary for 6 applications.}")
    a("\\label{tab:sealing-summary}")
    a("\\begin{tabular}{P{1.6cm} C{0.4cm} C{0.4cm} C{0.4cm} C{0.4cm} C{0.4cm} C{1cm} C{1cm} C{1cm}}")
    a("\\toprule")
    a("& \\multirow{2}{*}{\\rotatebox{90}{\\textbf{\\#Compartments}}}"
      "& \\multicolumn{4}{c}{\\textbf{Struct Types}} "
      "& \\multicolumn{3}{c}{\\textbf{Instrumentation Points}} \\\\")
    a("\\cmidrule(lr){3-6} \\cmidrule(lr){7-9}")
    a("\\textbf{App} &")
    a(" &")
    for h in ["Shared", "Seal", "Acc.", "NoSeal", "Seal Ins.", "Unseal Ins."]:
        a("\\rotatebox{90}{\\textbf{%s}} &" % h)
    a("\\rotatebox{90}{\\textbf{Acc. Repl.}} \\\\")
    a("\\midrule")
    t = dict(shared=0, seal=0, acc=0, noseal=0, si=0, ui=0, ar=0)
    for app in APPS:
        if app not in rows:
            continue
        r = rows[app]
        for k in t:
            t[k] += r[k]
        a("%-9s & %d & %d & %d & %d & %d & %s & %s & %d \\\\" % (
            app, r["cmp"], r["shared"], r["seal"], r["acc"], r["noseal"],
            "{:,}".format(r["si"]), "{:,}".format(r["ui"]), r["ar"]))
    a("\\midrule")
    a("\\textbf{Total} &  & \\textbf{%d} & \\textbf{%d} & \\textbf{%d} & "
      "\\textbf{%d} & \\textbf{%s} & \\textbf{%s} & \\textbf{%d} \\\\" % (
          t["shared"], t["seal"], t["acc"], t["noseal"],
          "{:,}".format(t["si"]), "{:,}".format(t["ui"]), t["ar"]))
    a("\\bottomrule")
    a("\\end{tabular}")
    a("\\end{table}")
    return "\n".join(out)


def collect_accessor_types(ws, include_unknown):
    """Types needing accessors (or excluded as cannot-seal), unioned over apps."""
    agg = {}
    for app in APPS:
        rep = load(ws, app)
        if rep is None:
            continue
        for st in rep["shared_types"]:
            if not keep(st["owner"], include_unknown):
                continue
            for e in st.get("shared_with", []):
                rec = e.get("sealing_recommendation")
                if rec not in ("needs_accessor", "cannot_seal", "address_taken"):
                    continue
                d = agg.setdefault((st["owner"], st["type"]),
                                   dict(total=st["total_fields"], apps=set(),
                                        fields=set(), recs=set()))
                d["apps"].add(app)
                d["fields"].update(e.get("fields_accessed") or [])
                d["recs"].add(rec)
    # Drop entries with no resolvable fields — nothing meaningful to report.
    return {k: v for k, v in agg.items() if v["total"] > 0}


def table_accessors(agg):
    order = ["zlib_merged", "openssl_merged", "pcre2_merged", "libevent_merged"]
    by_owner = {}
    for (owner, ty), d in agg.items():
        by_owner.setdefault(owner, []).append((ty, d))
    for v in by_owner.values():
        v.sort(key=lambda x: -len(x[1]["apps"]))

    notes, marker = [], {}
    for owner in order:
        for ty, _ in by_owner.get(owner, []):
            if ty in SHORT_NAME:
                notes.append(SHORT_NAME[ty][1])
                marker[ty] = len(notes)

    out = []
    a = out.append
    a("% Table 2: Accessor types  (generated by results/macrobenchmarks/scripts/gen_tables.py)")
    a("\\begin{table}[t]")
    a("\\centering")
    a("\\caption{Struct types requiring accessor functions. "
      "\\#Fields reports the number of fields accessed by non-owning "
      "compartments (union across all consuming applications) over the total "
      "number of fields in the struct. "
      "\\textsuperscript{\\dag}Cannot-seal: all fields accessed by non-owner; "
      "excluded from sealing.}")
    a("\\label{tab:accessor-types}")
    a("\\begin{tabular}{P{0.8cm} P{1.8cm} P{2.9cm} C{0.75cm} C{0.55cm}}")
    a("\\toprule")
    a("\\textbf{Owner} & \\textbf{Struct Type} & \\textbf{Apps} & "
      "\\textbf{\\#Fields} & \\textbf{Struct Ptr} \\\\")
    a("\\midrule")

    first = True
    for owner in order:
        entries = by_owner.get(owner, [])
        if not entries:
            continue
        if not first:
            a("\\midrule")
        first = False
        label = OWNER_LABEL.get(owner, owner)
        if len(entries) > 1:
            a("\\multirow{%d}{*}{\\rotatebox{90}{%s}}" % (len(entries), label))
        for i, (ty, d) in enumerate(entries):
            short = SHORT_NAME.get(ty, (tex(strip_struct(ty)), None))[0]
            sup = str(marker[ty]) if ty in marker else ""
            if "cannot_seal" in d["recs"]:
                sup += ",\\dag" if sup else "\\dag"
            sp = STRUCT_PTR.get(ty)
            sp_tex = ("\\textcolor{red}{Yes}" if sp
                      else "\\textcolor{green!50!black}{No}") if sp is not None \
                     else "\\textcolor{gray}{?}"
            lead = "  & " if len(entries) > 1 else ""
            if len(entries) == 1:
                lead = "%s & " % label
            a("%s%s\\textsuperscript{%s} & %s & %d/%d & %s \\\\" % (
                lead, short, sup, ", ".join(sorted(d["apps"])),
                len(d["fields"]), d["total"], sp_tex))
    a("\\bottomrule")
    a("\\end{tabular}")
    a("")
    a("\\vspace{2pt}")
    a("{\\scriptsize")
    for i, n in enumerate(notes, 1):
        a("\\textsuperscript{%d}\\texttt{%s}\\quad" % (i, n))
    a("}")
    a("\\end{table}")
    return "\n".join(out)


def seal_point_weight(ws, app):
    """How many seal_points each type accounts for, as a relevance ranking.

    "Representative" in the shared-types table means the types that actually
    drive the instrumentation, not the alphabetically first. Counting the
    seal_points that name each type gives a data-driven ordering; the number
    of sharing compartments does not, because with 2-3 compartments per app it
    is almost always 1 and the sort degenerates to alphabetical.
    """
    p = os.path.join(ws, app, "generated", "instrumentation_config.json")
    w = {}
    if not os.path.exists(p):
        return w
    with open(p) as f:
        cfg = json.load(f)
    for sp in cfg.get("seal_points") or []:
        t = sp.get("type_name")
        if t:
            w[t] = w.get(t, 0) + 1
    return w


def table_shared(ws, include_unknown, per_lib_max):
    out = []
    a = out.append
    a("% Table 3: Shared types  (generated by results/macrobenchmarks/scripts/gen_tables.py)")
    a("\\begin{table*}[t]")
    a("\\centering")
    a("\\caption{Applications, their library compartments, and representative "
      "struct types shared across compartment boundaries.}")
    a("\\label{tab:shared-types-examples}")
    a("\\begin{tabular}{lll}")
    a("\\toprule")
    a("\\textbf{App} & \\textbf{Library} & \\textbf{Example types} \\\\")
    a("\\midrule")
    apps = [x for x in APPS if load(ws, x) is not None]
    for n, app in enumerate(apps):
        rep = load(ws, app)
        weight = seal_point_weight(ws, app)
        by_owner = {}
        for st in rep["shared_types"]:
            if not keep(st["owner"], include_unknown):
                continue
            if st["owner"] == app + "_merged":      # app's own types
                continue
            by_owner.setdefault(st["owner"], []).append(
                (weight.get(st["type"], 0), st["type"]))
        if not by_owner:
            continue
        if n:
            a("\\midrule")
        owners = sorted(by_owner, key=lambda o: OWNER_LABEL.get(o, o))
        head = ("\\multirow{%d}{*}{%s}" % (len(owners), app.capitalize())
                if len(owners) > 1 else app.capitalize())
        for i, owner in enumerate(owners):
            # Most-shared first (that is what "representative" means here),
            # ties broken alphabetically rather than reverse-alphabetically.
            types = [t for _, t in sorted(by_owner[owner],
                                          key=lambda x: (-x[0], x[1]))]
            shown = ", ".join("\\texttt{%s}" % tex(strip_struct(t))
                              for t in types[:per_lib_max])
            a("%s & %s & %s \\\\" % (head if i == 0 else "",
                                     OWNER_LABEL.get(owner, owner), shown))
    a("\\bottomrule")
    a("\\end{tabular}")
    a("\\end{table*}")
    return "\n".join(out)


def default_workspace():
    """Where to read pipeline output from, when --workspace is not given.

    Prefers a live pipeline run, falls back to the outputs checked into the
    repository so the tables regenerate from a clean checkout without CHERI
    hardware. Resolved relative to this file, so the cwd does not matter.
    """
    env = os.environ.get("WORKSPACE_DIR")
    if env:
        return env
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(os.path.dirname(here))   # <repo>/
    live = os.path.join(repo, "workspace")
    if os.path.isdir(live):
        return live
    return os.path.join(repo, "results", "workspace")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--workspace", default=default_workspace(),
                    help="path to the pipeline workspace (default: $WORKSPACE_DIR "
                         "if set, else <repo>/workspace if it exists, else the "
                         "checked-in results/workspace)")
    ap.add_argument("--table", choices=["summary", "accessors", "shared", "all"],
                    default="all", help="which table to emit (default: all)")
    ap.add_argument("--include-unknown", action="store_true",
                    help="count types whose owner could not be resolved "
                         "(0-field opaque declarations); off by default")
    ap.add_argument("--max-types", type=int, default=4,
                    help="max example types per library in the shared table")
    args = ap.parse_args()

    if not os.path.isdir(args.workspace):
        sys.exit("no such workspace: %s" % args.workspace)

    rows = summarize(args.workspace, args.include_unknown)
    if not rows:
        sys.exit("no sealing_report.json found under %s" % args.workspace)

    parts = []
    if args.table in ("summary", "all"):
        parts.append(table_summary(rows))
    if args.table in ("accessors", "all"):
        parts.append(table_accessors(
            collect_accessor_types(args.workspace, args.include_unknown)))
    if args.table in ("shared", "all"):
        parts.append(table_shared(args.workspace, args.include_unknown,
                                  args.max_types))
    print("\n\n".join(parts))


if __name__ == "__main__":
    main()
