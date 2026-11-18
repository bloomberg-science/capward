#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# run_seal_analysis.sh — Full build orchestrator for the capward pipeline.
#
# Runs, in dependency order, everything needed to produce the instrumented (and
# baseline) binaries + sealed libraries for the evaluated applications:
#   A. LLVM pass plugins         (build/passes/build_passes_morello.sh)
#   B. Library bitcode producers (build/libraries/build_<lib>.sh) — only the
#      libraries the selected apps actually need
#   C. Per-app build             (build/apps/build_<app>_morello.sh) — each does
#      LTO save-temps bitcode -> seal_pipeline.sh (analyze + instrument) ->
#      link (sealed + baseline)
#
# The environment is validated first via set_env.sh, which ABORTS the run if any
# required path is missing. Override paths by exporting them before running
# (see pipeline/set_env.sh).
#
# Usage:
#   ./run_seal_analysis.sh                 # all evaluated apps
#   ./run_seal_analysis.sh --app redis     # one app
#   ./run_seal_analysis.sh --clean         # wipe workspace intermediates first
#   ./run_seal_analysis.sh --distclean     # ...and force a full recompile too
#   ./run_seal_analysis.sh --skip-passes   # reuse already-built pass plugins
#   ./run_seal_analysis.sh --skip-libs     # reuse already-built library bitcode
#   ./run_seal_analysis.sh --embedded-fields  # force embedded-field sealing on for all
#   ./run_seal_analysis.sh --list          # print evaluated apps and exit
#
# --embedded-fields enables embedded-foreign-field sealing (a locally-owned
# struct embedding a foreign-owned struct BY VALUE whose address is taken, e.g.
# curl's zlib_writer.z_stream) for EVERY app; --no-embedded-fields disables it
# for every app. Give neither and each app uses its own default, which
# seal_pipeline.sh owns: on for curl, off elsewhere. Off is right elsewhere
# because the seal-at-derivation implementation rewrites every use of the
# derived pointer, which breaks direct field accesses that alias the derivation
# — see nginx's ngx_http_gzip_filter_add_data.
#
# Exported as SEAL_EMBEDDED_FIELDS, and only when explicitly given, so each
# app's build script passes it to seal_pipeline.sh without needing its own flag.
#
# --clean vs --distclean
#   --clean     wipes workspace/<app>/{bitcode,manifests,generated,instrumented,
#               build,baseline}. Everything that determines the reported numbers
#               — pass plugins, analyzer, codegen, seal pass, both links — is
#               then re-derived from scratch. But the C sources are NOT
#               recompiled: each tree is configure-stamp-gated and its `make` is
#               incremental, so the same bitcode is simply re-copied in.
#   --distclean implies --clean, and additionally removes each source tree's
#               configure stamp AND its objects (via DISTCLEAN=1, honoured by
#               every build/apps + build/libraries script) plus the library
#               workspaces. Use this whenever a COMPILE flag changed — e.g. the
#               -O0/-O2 switch — because --clean alone cannot see such a change:
#               the stamp blocks the reconfigure and make sees no changed
#               sources, so you would silently keep the old bitcode and get
#               numbers with no indication anything was stale.
#               Much slower (openssl dominates); it is the from-bare-source run.
#
# Scope: the six evaluated applications only. tar (0 shared types -> nothing to
# seal), opensmtpd and httpd are out of evaluation scope and their build
# scripts are not included in this repository.

set -e

REPO_DIR="${REPO_DIR:-$HOME/capward}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$REPO_DIR/workspace}"
CAPW="$REPO_DIR/pipeline"

# The six evaluated apps (cheapest first for faster feedback).
ALL_APPS="redis wget curl lighttpd nginx memcached"

SINGLE_APP=""
CLEAN=""
# Honour an inherited DISTCLEAN=1 rather than clobbering it: the per-app and
# per-library scripts read this same variable directly, so `DISTCLEAN=1 sh
# run_seal_analysis.sh ...` must mean the same thing as `--distclean`.
DISTCLEAN="${DISTCLEAN:-}"
SKIP_PASSES=""
SKIP_LIBS=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --app)          SINGLE_APP="$2"; shift 2;;
        --clean)        CLEAN=1; shift;;
        --distclean)    CLEAN=1; DISTCLEAN=1; shift;;
        --skip-passes)  SKIP_PASSES=1; shift;;
        --skip-libs)    SKIP_LIBS=1; shift;;
        --embedded-fields)    SEAL_EMBEDDED_FIELDS=1; shift;;
        --no-embedded-fields) SEAL_EMBEDDED_FIELDS=0; shift;;
        --list)         echo "$ALL_APPS"; exit 0;;
        *) echo "Unknown option: $1" >&2; exit 1;;
    esac
done

# A distclean implies a clean, however it was requested (flag or environment).
if [ -n "$DISTCLEAN" ]; then
    CLEAN=1
fi

# --distclean removes the library workspaces, so skipping the library rebuild
# would leave the apps with no library bitcode to consume. Fail now rather than
# midway through, with a clearer message than "Missing openssl_merged.bc".
if [ -n "$DISTCLEAN" ] && [ -n "$SKIP_LIBS" ]; then
    echo "ERROR: --distclean and --skip-libs are contradictory." >&2
    echo "  --distclean deletes workspace/libraries/, which --skip-libs then" >&2
    echo "  refuses to rebuild. Drop one of them." >&2
    exit 1
fi

# Consumed by every build/apps/* and build/libraries/* script to wipe its own
# configure stamp and objects. Each tree knows its own layout, so the knowledge
# lives there rather than being duplicated here.
export DISTCLEAN

# Consumed by seal_pipeline.sh (invoked from each app build script), which turns
# it into the matching --embedded-foreign-seals / -seal-embedded-fields flags
# for steps 5 and 6.
#
# Exported ONLY when the user made an explicit choice. Forcing it to 0 here
# would override seal_pipeline.sh's per-app default and silently stop curl
# reproducing its recorded results, since an unset variable is how that script
# recognises "nobody has said".
if [ -n "${SEAL_EMBEDDED_FIELDS:-}" ]; then
    export SEAL_EMBEDDED_FIELDS
fi

APPS="$ALL_APPS"
if [ -n "$SINGLE_APP" ]; then
    # Reject anything outside the evaluated set rather than failing later with a
    # confusing "no build script" error.
    case " $ALL_APPS " in
        *" $SINGLE_APP "*) ;;
        *) echo "ERROR: '$SINGLE_APP' is not an evaluated app." >&2
           echo "  Evaluated apps: $ALL_APPS" >&2
           exit 1;;
    esac
    APPS="$SINGLE_APP"
fi

# Libraries required by each app (compartment producers under build/libraries/).
libs_for() {
    case "$1" in
        nginx)               echo "openssl pcre2 zlib" ;;
        redis)               echo "openssl" ;;
        wget|curl|lighttpd)  echo "openssl zlib" ;;
        memcached)           echo "openssl libevent" ;;
        *)                   echo "" ;;
    esac
}

bin_for() {
    case "$1" in
        redis)     echo "redis-server" ;;
        *)         echo "$1" ;;
    esac
}

# Union of the libraries the selected apps need. Computed here (not inside
# section B) because --distclean must also clear these libraries' workspaces.
NEEDED_LIBS=""
for app in $APPS; do
    for l in $(libs_for "$app"); do
        case " $NEEDED_LIBS " in
            *" $l "*) ;;
            *) NEEDED_LIBS="$NEEDED_LIBS $l" ;;
        esac
    done
done

echo "======================================================================"
echo "capward — full build orchestrator"
echo "======================================================================"
echo "Repo: $REPO_DIR"
echo "Apps: $APPS"
case "${SEAL_EMBEDDED_FIELDS:-}" in
    1)  echo "Embedded-foreign-field sealing: ENABLED for all apps (--embedded-fields)";;
    0)  echo "Embedded-foreign-field sealing: disabled for all apps (--no-embedded-fields)";;
    *)  echo "Embedded-foreign-field sealing: per-app default (on for curl, off elsewhere)";;
esac
echo ""

# --- Validate environment (required paths must exist) ---
if . "$CAPW/set_env.sh"; then
    :
else
    echo "ERROR: environment validation failed — fix the paths above before running." >&2
    exit 1
fi
echo ""

# --- Optional clean of workspace intermediates for the selected apps ---
if [ -n "$CLEAN" ]; then
    echo ">>> Cleaning workspace intermediates for:$APPS"
    for app in $APPS; do
        WKSP="$WORKSPACE_DIR/$app"
        [ -d "$WKSP" ] && rm -rf \
            "$WKSP/bitcode" "$WKSP/manifests" "$WKSP/generated" \
            "$WKSP/instrumented" "$WKSP/build" "$WKSP/baseline"
    done
    echo ""
fi

# --- Optional distclean: also drop the library workspaces. The source trees
#     themselves are wiped by each build script via the exported DISTCLEAN=1. ---
if [ -n "$DISTCLEAN" ]; then
    echo ">>> DISTCLEAN: removing library workspaces for:$NEEDED_LIBS"
    for lib in $NEEDED_LIBS; do
        rm -rf "$WORKSPACE_DIR/libraries/$lib"
    done
    echo "    Source trees (configure stamps + objects) are wiped by each"
    echo "    build script; every compartment is recompiled from source."
    echo ""
fi

# ============================================================================
# A. LLVM pass plugins
# ============================================================================
if [ -z "$SKIP_PASSES" ]; then
    echo ">>> [A] Building LLVM pass plugins..."
    sh "$CAPW/build/passes/build_passes_morello.sh"
    echo ""
fi

# ============================================================================
# B. Library bitcode (union of what the selected apps need)
# ============================================================================
if [ -z "$SKIP_LIBS" ]; then
    echo ">>> [B] Building library bitcode:$NEEDED_LIBS"
    for lib in $NEEDED_LIBS; do
        echo "    --- library: $lib ---"
        sh "$CAPW/build/libraries/build_${lib}.sh"
    done
    echo ""
fi

# ============================================================================
# C. Per-app build (bitcode -> instrument -> link). Each app script is the
#    single source of truth for that app's build+link (no duplicated linking).
# ============================================================================
PASS_COUNT=0
FAIL_COUNT=0
FAILED_APPS=""

for app in $APPS; do
    script="$CAPW/build/apps/build_${app}_morello.sh"
    echo ""
    echo "======================================================================"
    echo ">>> [C] $app"
    echo "======================================================================"
    if [ ! -f "$script" ]; then
        echo "    ERROR: no build script: $script" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_APPS="$FAILED_APPS $app"
        continue
    fi
    if sh "$script"; then
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_APPS="$FAILED_APPS $app"
        echo ">>> $app: FAILED"
    fi
done

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "======================================================================"
echo "Build Summary"
echo "======================================================================"
echo "  Passed: $PASS_COUNT   Failed: $FAIL_COUNT"
[ -n "$FAILED_APPS" ] && echo "  Failed apps:$FAILED_APPS"
echo ""

echo "Binaries (instrumented / baseline):"
for app in $APPS; do
    WKSP="$WORKSPACE_DIR/$app"
    BIN=$(bin_for "$app")
    inst="MISSING"; base="MISSING"
    [ -f "$WKSP/instrumented/$BIN" ] && inst="ok"
    [ -f "$WKSP/baseline/$BIN" ]     && base="ok"
    printf "  %-12s instrumented:%-9s baseline:%s\n" "$app" "$inst" "$base"
done

echo ""
echo "Instrumentation stats (seal/unseal insertions):"
for app in $APPS; do
    WKSP="$WORKSPACE_DIR/$app"
    if ls "$WKSP/build/instrument_"*.log >/dev/null 2>&1; then
        echo "  --- $app ---"
        grep "seal insertions\|indirect call unseals" "$WKSP/build/instrument_"*.log 2>/dev/null | \
            sed "s|$WKSP/build/instrument_||" | sed 's/\.log:/: /'
    fi
done

echo ""
[ "$FAIL_COUNT" -eq 0 ]
