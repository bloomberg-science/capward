#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# seal_pipeline.sh — Generic seal instrumentation pipeline (steps 3-7)
#
# Runs the analysis + instrumentation pipeline on pre-built bitcode.
# This script is app-agnostic — the caller specifies which libraries
# to analyze and instrument via a simple config.
#
# Usage:
#   ./seal_pipeline.sh --app <name> --libs "lib1:otype lib2:otype ..."
#                      [--embedded-fields | --no-embedded-fields]
#
# --embedded-fields enables embedded-foreign-field sealing: the case where a
# locally-owned struct embeds a foreign-owned struct BY VALUE and the consumer
# takes its address (curl's zlib_writer.z_stream, nginx's
# ngx_http_gzip_ctx_t.zstream). It must be set for BOTH step 5 and step 6 or the
# two disagree, so this script drives them together from one switch.
#
# THE DEFAULT IS PER-APPLICATION (see EMBEDDED_FIELDS_DEFAULT below): ON for
# curl, OFF for everything else. curl is the one evaluated application whose
# recorded results in results/workspace/ were produced with the feature on, so
# reproducing them must not depend on the evaluator knowing to pass a flag. It
# is off elsewhere because the seal-at-derivation implementation rewrites every
# use of the derived pointer, which breaks direct field accesses that alias the
# derivation — see nginx's ngx_http_gzip_filter_add_data.
#
# Precedence, highest first:
#   1. --embedded-fields / --no-embedded-fields on the command line
#   2. SEAL_EMBEDDED_FIELDS=1|0 in the environment (how run_seal_analysis.sh
#      forwards an explicit choice through the per-app build scripts)
#   3. the per-app default
#
# So an explicit --no-embedded-fields still turns it off for curl.
#
# Example:
#   ./seal_pipeline.sh --app redis --libs "redis:0 openssl:1"
#   ./seal_pipeline.sh --app nginx --libs "nginx:0 openssl:1 pcre2:2 zlib:3"
#
# Prerequisites:
#   - Merged bitcode in workspace/<app>/bitcode/<lib>_merged.bc
#   - LLVM passes built in analysis/llvm-passes/build_morello/
#   - Python scripts in analysis/python/

set -e

# ============================================================================
# Configuration
# ============================================================================

REPO_DIR="${REPO_DIR:-$HOME/capward}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$REPO_DIR/workspace}"
LLVM_PREFIX="${LLVM_PREFIX:-/usr/local64/llvm-morello}"
LLVM_BIN="${LLVM_BIN:-$LLVM_PREFIX/bin}"
OPT="${LLVM_BIN}/opt"

PASS_DIR="${REPO_DIR}/analysis/llvm-passes/build_morello"
INSTRUMENT_PASS="${PASS_DIR}/libSealInstrumentationPass.so"
ANALYZER_PASS="${PASS_DIR}/libCrossCompartmentTypeAnalyzer.so"
CROSS_COMPARTMENT_ANALYZER="${REPO_DIR}/analysis/python/cross_compartment_analyzer.py"
SEAL_CODEGEN="${REPO_DIR}/analysis/python/seal_codegen.py"

# Parse arguments
APP=""
LIBS=""
SKIP_ANALYSIS=""
SKIP_INSTRUMENT=""
# Empty means "nobody has said", which is what lets the per-app default apply
# once --app is known. Inherited from the environment so run_seal_analysis.sh
# can forward an explicit choice once and every per-app build script passes it
# through without modification.
EMBEDDED_FIELDS="${SEAL_EMBEDDED_FIELDS:-}"

# Applications whose embedded-foreign-field sealing defaults to ON. Space
# separated, matched whole-word. See the header for why curl is the only one.
EMBEDDED_FIELDS_DEFAULT_ON="curl"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --app)            APP="$2"; shift 2;;
        --libs)           LIBS="$2"; shift 2;;
        --skip-analysis)  SKIP_ANALYSIS=1; shift;;
        --skip-instrument) SKIP_INSTRUMENT=1; shift;;
        --embedded-fields) EMBEDDED_FIELDS=1; shift;;
        --no-embedded-fields) EMBEDDED_FIELDS=0; shift;;
        --repo-dir)       REPO_DIR="$2"; shift 2;;
        --llvm-bin)       LLVM_BIN="$2"; shift 2;;
        *) echo "Unknown option: $1"; exit 1;;
    esac
done

if [ -z "$APP" ] || [ -z "$LIBS" ]; then
    echo "Usage: $0 --app <name> --libs \"lib1:otype lib2:otype ...\""
    echo ""
    echo "Example: $0 --app redis --libs \"redis:0 openssl:1\""
    exit 1
fi

# Resolve the per-app default, now that --app is known. Only reached when
# neither a flag nor the environment said anything.
if [ -z "$EMBEDDED_FIELDS" ]; then
    case " $EMBEDDED_FIELDS_DEFAULT_ON " in
        *" $APP "*) EMBEDDED_FIELDS=1; EMBEDDED_FIELDS_WHY=" (default for $APP)";;
        *)          EMBEDDED_FIELDS=0; EMBEDDED_FIELDS_WHY=" (default)";;
    esac
else
    EMBEDDED_FIELDS_WHY=" (requested)"
fi

# Translate the one switch into the step-5 and step-6 flags, which must agree.
if [ "$EMBEDDED_FIELDS" = "1" ]; then
    CODEGEN_EMBEDDED_FLAG="--embedded-foreign-seals"
    PASS_EMBEDDED_FLAG="-seal-embedded-fields=true"
else
    CODEGEN_EMBEDDED_FLAG=""
    PASS_EMBEDDED_FLAG="-seal-embedded-fields=false"
fi

WKSP="${WORKSPACE_DIR}/${APP}"
BITCODE_DIR="${WKSP}/bitcode"
MANIFEST_DIR="${WKSP}/manifests"
GENERATED_DIR="${WKSP}/generated"
INSTRUMENTED_DIR="${WKSP}/instrumented"
BUILD_DIR="${WKSP}/build"

mkdir -p "$BITCODE_DIR" "$MANIFEST_DIR" "$GENERATED_DIR" "$INSTRUMENTED_DIR" "$BUILD_DIR"

echo "======================================================================"
echo "Seal Pipeline — ${APP}"
echo "======================================================================"
echo "Workspace:  $WKSP"
echo "Libraries:  $LIBS"
if [ "$EMBEDDED_FIELDS" = "1" ]; then
    echo "Embedded-foreign-field sealing: ENABLED${EMBEDDED_FIELDS_WHY}"
else
    echo "Embedded-foreign-field sealing: disabled${EMBEDDED_FIELDS_WHY} (--embedded-fields to enable)"
fi
echo ""

# Verify bitcode files exist (fail loudly — never proceed on missing input)
for entry in $LIBS; do
    lib=$(echo "$entry" | cut -d: -f1)
    if [ ! -f "$BITCODE_DIR/${lib}_merged.bc" ]; then
        echo "ERROR: Missing ${BITCODE_DIR}/${lib}_merged.bc" >&2
        echo "  The app build script must populate this before running the pipeline:" >&2
        echo "    - app compartment bitcode -> produced by build_${APP}_morello.sh (LTO save-temps)" >&2
        echo "    - library bitcode         -> produced by pipeline/build/libraries/build_${lib}.sh" >&2
        exit 1
    fi
done

# ============================================================================
# Step 3: CrossCompartmentTypeAnalyzer (per library)
# ============================================================================

if [ -z "$SKIP_ANALYSIS" ]; then

echo ">>> Step 3: Running cross-compartment type analysis..."

for entry in $LIBS; do
    lib=$(echo "$entry" | cut -d: -f1)
    bc_file="$BITCODE_DIR/${lib}_merged.bc"
    annotated="$BITCODE_DIR/${lib}_merged.annotated.bc"
    manifest="$MANIFEST_DIR/${lib}_manifest.json"

    # Delete stale outputs so a failed pass can never fall back to a previous run
    rm -f "$annotated" "$manifest" "$MANIFEST_DIR/${lib}_stderr.txt"

    echo "    Analyzing ${lib}..."
    if ! $OPT -load-pass-plugin="$ANALYZER_PASS" \
        -passes="cross-compartment-type-analyzer" \
        -o "$annotated" \
        "$bc_file" \
        2>"$MANIFEST_DIR/${lib}_stderr.txt"; then
        echo "ERROR: analyzer pass failed for ${lib}" >&2
        cat "$MANIFEST_DIR/${lib}_stderr.txt" >&2
        exit 1
    fi

    # Extract JSON manifest from stderr.
    # TODO(post-paper): have the pass write the manifest to a file instead of
    # scraping it from stderr. See docs/design/IMPLEMENTATION_TODO.md (item 1).
    sed -n '/===CROSS_COMPARTMENT_JSON_BEGIN===/,/===CROSS_COMPARTMENT_JSON_END===/p' \
        "$MANIFEST_DIR/${lib}_stderr.txt" | \
        grep -v "===CROSS_COMPARTMENT_JSON" > "$manifest" || true

    # A missing/empty manifest or annotated bitcode is a hard failure
    if [ ! -s "$manifest" ]; then
        echo "ERROR: no cross-compartment manifest extracted for ${lib}" >&2
        echo "  (analyzer produced no ===CROSS_COMPARTMENT_JSON=== block; see" >&2
        echo "   $MANIFEST_DIR/${lib}_stderr.txt)" >&2
        exit 1
    fi
    if [ ! -s "$annotated" ]; then
        echo "ERROR: annotated bitcode not produced for ${lib}: $annotated" >&2
        exit 1
    fi
    echo "    → ${lib}_manifest.json"
done

# ============================================================================
# Step 4: cross_compartment_analyzer.py
# ============================================================================

echo ">>> Step 4: Running cross-compartment analyzer..."

MANIFEST_ARGS=""
for entry in $LIBS; do
    lib=$(echo "$entry" | cut -d: -f1)
    MANIFEST_ARGS="$MANIFEST_ARGS $MANIFEST_DIR/${lib}_manifest.json"
done

# Delete stale output so a failed run cannot fall back to a previous report
rm -f "$GENERATED_DIR/sealing_report.json"

if ! python3 "$CROSS_COMPARTMENT_ANALYZER" \
    --manifests $MANIFEST_ARGS \
    --output "$GENERATED_DIR/sealing_report.json" \
    --program-name "$APP"; then
    echo "ERROR: cross_compartment_analyzer.py failed for ${APP}" >&2
    exit 1
fi

if [ ! -s "$GENERATED_DIR/sealing_report.json" ]; then
    echo "ERROR: sealing_report.json not produced for ${APP}" >&2
    exit 1
fi
echo "    → sealing_report.json"

# ============================================================================
# Step 5: seal_codegen.py
# ============================================================================

echo ">>> Step 5: Running seal code generator..."

# Delete stale config so a failed codegen cannot leave the previous run's config
rm -f "$GENERATED_DIR/instrumentation_config.json"

if ! python3 "$SEAL_CODEGEN" \
    --report "$GENERATED_DIR/sealing_report.json" \
    --manifests $MANIFEST_ARGS \
    $CODEGEN_EMBEDDED_FLAG \
    --output-dir "$GENERATED_DIR"; then
    echo "ERROR: seal_codegen.py failed for ${APP}" >&2
    exit 1
fi

if [ ! -s "$GENERATED_DIR/instrumentation_config.json" ]; then
    echo "ERROR: instrumentation_config.json not produced for ${APP}" >&2
    exit 1
fi
echo "    → instrumentation_config.json"

fi  # SKIP_ANALYSIS

# ============================================================================
# Step 6: SealInstrumentationPass (per library)
# ============================================================================

if [ -z "$SKIP_INSTRUMENT" ]; then

echo ">>> Step 6: Running seal instrumentation pass..."

SEAL_CONFIG="$GENERATED_DIR/instrumentation_config.json"
if [ ! -s "$SEAL_CONFIG" ]; then
    echo "ERROR: $SEAL_CONFIG not found or empty (step 5 must run first)" >&2
    exit 1
fi

for entry in $LIBS; do
    lib=$(echo "$entry" | cut -d: -f1)
    otype=$(echo "$entry" | cut -d: -f2)
    bc_in="$BITCODE_DIR/${lib}_merged.annotated.bc"
    bc_out="$INSTRUMENTED_DIR/${lib}_instrumented.bc"
    log="$BUILD_DIR/instrument_${lib}.log"

    if [ ! -s "$bc_in" ]; then
        echo "ERROR: annotated bitcode missing for ${lib}: $bc_in" >&2
        echo "  (step 3 must produce it before instrumentation)" >&2
        exit 1
    fi

    # Delete stale output so a failed pass cannot leave a previous run's bitcode
    rm -f "$bc_out"

    echo "    Instrumenting ${lib} (otype=${otype})..."
    # Plain redirect (no pipe) so the pass exit code is authoritative even on
    # shells without pipefail; the log is echoed afterwards.
    if ! $OPT \
        -load-pass-plugin="$INSTRUMENT_PASS" \
        -passes=seal-instrument \
        -seal-config="$SEAL_CONFIG" \
        -seal-module-name="${lib}_merged" \
        -seal-otype="$otype" \
        "$PASS_EMBEDDED_FLAG" \
        "$bc_in" \
        -o "$bc_out" \
        > "$log" 2>&1; then
        cat "$log" >&2
        echo "ERROR: instrumentation pass failed for ${lib}" >&2
        exit 1
    fi
    cat "$log"

    if [ ! -s "$bc_out" ]; then
        echo "ERROR: instrumented bitcode not produced for ${lib}: $bc_out" >&2
        exit 1
    fi
    echo "    → ${bc_out}"
done

fi  # SKIP_INSTRUMENT

# ============================================================================
# Step 7: Stage compartment bitcode for LTO linking — for EACH compartment
# expose both the instrumented bitcode (sealed, from step 6) and the plain
# pre-instrument bitcode (baseline) under a uniform naming convention that the
# per-app link step consumes with a single `clang -flto` call:
#
#     <lib>.bc           = sealed   (instrumented)
#     <lib>_baseline.bc  = baseline (plain, pre-instrument)
#
# Native codegen no longer happens here. Standalone `llc` on Morello does not
# inherit the clang driver's purecap backend defaults (cap-table ABI, code-ptr
# relocations), so it emits GOT relocations the linker lays out with 8-byte
# entries — capability (LD128) GOT loads then fail with "improper alignment for
# relocation R_MORELLO_LD128_GOT_LO12_NC". Deferring codegen to `clang -flto`
# routes it through the same LTO-backend-in-lld path the native `make` build
# uses, which produces a consistent 16-byte capability GOT. Baseline and sealed
# go through the IDENTICAL link path, so the binaries differ only by the seal
# pass. See docs/design/IMPLEMENTATION_TODO.md / the sealing memory for context.
# ============================================================================

echo ">>> Step 7: Staging compartment bitcode for LTO linking (sealed + baseline)..."

for entry in $LIBS; do
    lib=$(echo "$entry" | cut -d: -f1)
    sealed_bc="$INSTRUMENTED_DIR/${lib}_instrumented.bc"
    base_bc="$BITCODE_DIR/${lib}_merged.bc"
    sealed_out="$BUILD_DIR/${lib}.bc"
    base_out="$BUILD_DIR/${lib}_baseline.bc"

    if [ ! -s "$sealed_bc" ]; then
        echo "ERROR: missing instrumented bitcode for ${lib}: $sealed_bc" >&2
        echo "  (step 6 must produce it; skipping here would silently stage stale bitcode)" >&2
        exit 1
    fi

    # Delete stale staged bitcode so a failed copy cannot leave a previous run's data
    rm -f "$sealed_out" "$base_out"

    cp "$sealed_bc" "$sealed_out"
    cp "$base_bc"   "$base_out"

    if [ ! -s "$sealed_out" ] || [ ! -s "$base_out" ]; then
        echo "ERROR: staged bitcode not produced for ${lib}: $sealed_out / $base_out" >&2
        exit 1
    fi
    echo "    → ${sealed_out}, ${base_out}"
done

echo ""
echo "======================================================================"
echo "Pipeline complete for ${APP}!"
echo ""
echo "  Sealed bitcode:   $BUILD_DIR/<lib>.bc"
echo "  Baseline bitcode: $BUILD_DIR/<lib>_baseline.bc"
echo "  Config:           $GENERATED_DIR/instrumentation_config.json"
echo ""
echo "  Next: the per-app build script links both the sealed binary/.so's and"
echo "  the baseline binary/.so's from this bitcode with a single 'clang -flto'"
echo "  call (codegen happens at link time)."
echo "======================================================================"
