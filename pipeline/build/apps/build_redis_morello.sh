#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# build_redis_morello.sh — Build seal-instrumented Redis on Morello/CheriBSD
#
# Compartments: redis(0), openssl(1)
# Source: Redis 7.0.12
# Deps: openssl from workspace/libraries/ (built by pipeline/build/libraries/)
#
# Bitcode via -flto + -Wl,-plugin-opt=save-temps: redis's own link emits
# src/redis-server.0.0.preopt.bc (the whole redis compartment). No per-.c
# bitcode collection, no manual llvm-link.

set -e

# --link-only runs ONLY step 8, linking from bitcode already staged in
# workspace/<app>/build/ by seal_pipeline.sh step 7. Steps 1-7 are skipped, so
# nothing is compiled from source and the application and library source trees
# need not be present. Use it to link the published compartment bitcode without
# an emulated from-source build.
LINK_ONLY=""
[ "$1" = "--link-only" ] && { LINK_ONLY=1; shift; }

REPO_DIR="${REPO_DIR:-$HOME/capward}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$REPO_DIR/workspace}"
LLVM_PREFIX="${LLVM_PREFIX:-/usr/local64/llvm-morello}"
LLVM_BIN="${LLVM_BIN:-$LLVM_PREFIX/bin}"
CC="${CC:-$LLVM_BIN/clang}"

# Defaults match pipeline/set_env.sh, which composes CHERI_CFLAGS from these
# three. Repeated here so the script still runs standalone; change them THERE.
# Natively on CheriBSD they expand to the compiler's own defaults, so they only
# bite when cross-compiling from Linux or macOS against a sysroot.
CHERI_TARGET="${CHERI_TARGET:-aarch64-unknown-freebsd15.0}"
SYSROOT="${SYSROOT:-/}"
SYSTEM_INCLUDE_DIR="${SYSTEM_INCLUDE_DIR:-/usr/include}"
CHERI_CFLAGS="${CHERI_CFLAGS:--target $CHERI_TARGET -march=morello -mabi=purecap --sysroot=$SYSROOT -isystem $SYSTEM_INCLUDE_DIR}"
CHERI_LDFLAGS="${CHERI_LDFLAGS:--target $CHERI_TARGET -march=morello -mabi=purecap --sysroot=$SYSROOT}"
# Optimisation level of the ANALYSIS bitcode. Override to experiment, e.g.
#   OPT_FLAGS="-O0 -g" DISTCLEAN=1 sh <this script>
# Keep -g: the analyzer needs debug info to attribute fields to types.
OPT_FLAGS="${OPT_FLAGS:--O2 -g}"
COMMON_CFLAGS="${OPT_FLAGS} ${CHERI_CFLAGS}"

REDIS_VERSION="${REDIS_VERSION:-7.0.12}"
REDIS_SRC="${REDIS_SRC:-$HOME/redis-${REDIS_VERSION}}"

WKSP="${WORKSPACE_DIR}/redis"
LIB_OPENSSL="${WORKSPACE_DIR}/libraries/openssl"
OPENSSL_SRC="${OPENSSL_SRC:-$HOME/lib_srcs/openssl}"
OPENSSL_BUILD="${OPENSSL_BUILD:-$OPENSSL_SRC/build_purecap}"

echo "======================================================================"
echo "Building seal-instrumented Redis ${REDIS_VERSION}"
echo "  Compartments: redis(0) openssl(1)"
echo "======================================================================"

if [ -z "$LINK_ONLY" ]; then

for f in "$LIB_OPENSSL/openssl_merged.bc" "$LIB_OPENSSL/libssl.so"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: $f not found. Run pipeline/build/libraries/build_openssl.sh first." >&2
        exit 1
    fi
done

# ============================================================================
# Step 1: Build redis with -flto + save-temps
#
# The redis-server link must succeed against the purecap libssl/libcrypto for
# the LTO plugin to emit src/redis-server.0.0.preopt.bc.
# NOTE: openssl -I/-L paths may need tuning to your Morello layout.
# ============================================================================

echo ">>> Step 1: Building redis (purecap, -flto save-temps)..."

cd "$REDIS_SRC"
# Unconditional — redis has no configure stamp, and this tree is always rebuilt
# from scratch. DISTCLEAN=1 (run_seal_analysis.sh --distclean) is therefore a
# no-op here: every run is already a distclean run.
gmake distclean >/dev/null 2>&1 || true
# uname_S=FreeBSD states the TARGET os. redis's Makefile derives it from the
# host's `uname -s`, which is right when building natively on CheriBSD and wrong
# when cross-compiling: a Linux host selects the Linux branch, which omits
# -lexecinfo, and the link then fails on undefined `backtrace` /
# `backtrace_symbols_fd` (config.h still sees __FreeBSD__ and enables
# HAVE_BACKTRACE). A command-line assignment overrides the makefile's `:=`, and
# it is a no-op natively, where uname -s already says FreeBSD.
gmake CC="$CC" \
    uname_S=FreeBSD \
    CFLAGS="${COMMON_CFLAGS} -flto -I${OPENSSL_BUILD}/include -I${OPENSSL_SRC}/include" \
    LDFLAGS="${CHERI_LDFLAGS} -flto -Wl,-plugin-opt=save-temps -L${LIB_OPENSSL}" \
    BUILD_TLS=yes \
    USE_JEMALLOC=no \
    MALLOC=libc \
    -j4

# ============================================================================
# Step 2: Collect bitcode
# ============================================================================

echo ">>> Step 2: Collecting bitcode..."
mkdir -p "$WKSP/bitcode"

PREOPT_BC="$REDIS_SRC/src/redis-server.0.0.preopt.bc"
if [ ! -f "$PREOPT_BC" ]; then
    echo "ERROR: $PREOPT_BC not found — did the link succeed with -flto save-temps?" >&2
    exit 1
fi

cp "$PREOPT_BC"                     "$WKSP/bitcode/redis_merged.bc"
cp "$LIB_OPENSSL/openssl_merged.bc" "$WKSP/bitcode/openssl_merged.bc"
echo "    → redis_merged.bc, openssl_merged.bc"

# ============================================================================
# Steps 3-7: Analysis + Instrumentation
# ============================================================================

echo ">>> Running seal pipeline..."
sh "${REPO_DIR}/pipeline/build/seal_pipeline.sh" \
    --app redis \
    --libs "redis:0 openssl:1"

else
    echo ">>> --link-only: skipping steps 1-7, linking staged bitcode"
    if ! ls "$WKSP/build/"*.bc >/dev/null 2>&1; then
        echo "ERROR: no staged bitcode in $WKSP/build/" >&2
        echo "  Run this script without --link-only to build it from source, or" >&2
        echo "  unpack the published compartment bitcode and run" >&2
        echo "  pipeline/build/seal_pipeline.sh to stage it." >&2
        exit 1
    fi
fi  # LINK_ONLY

# ============================================================================
# Step 8: Link
# ============================================================================

echo ">>> Step 8: Linking (sealed + baseline)..."

OBJ_DIR="$WKSP/build"
INSTRUMENTED_DIR="$WKSP/instrumented"

# Link one variant. $1 = bitcode suffix ("" = sealed | "_baseline"), $2 = out dir.
# codegen happens here via clang -flto (LTO backend in lld), NOT a prior llc
# step — see seal_pipeline.sh step 7 for why. Same sonames/flags in both
# variants, so baseline and sealed binaries differ only by which bitcode
# (instrumented vs plain) they are built from.
link_variant() {
    sfx="$1"; OUT="$2"; mkdir -p "$OUT"
    $CC $CHERI_CFLAGS -O2 -flto -shared -Wl,-soname,libssl_sealed.so \
        "$OBJ_DIR/openssl${sfx}.bc" -o "$OUT/libssl_sealed.so"
    $CC $CHERI_CFLAGS -O2 -flto "$OBJ_DIR/redis${sfx}.bc" \
        -L"$OUT" -lssl_sealed \
        -lthr -lm -ldl -lexecinfo \
        -o "$OUT/redis-server"
}

link_variant ""          "$INSTRUMENTED_DIR"
link_variant "_baseline" "$WKSP/baseline"
echo "    -> instrumented/redis-server + baseline/redis-server"

# ============================================================================
# Verify
# ============================================================================

echo ">>> Verification..."
file "$INSTRUMENTED_DIR/redis-server"
LD_LIBRARY_PATH="$INSTRUMENTED_DIR" "$INSTRUMENTED_DIR/redis-server" --version 2>&1 || true

echo "======================================================================"
echo "Build complete! Binary: $INSTRUMENTED_DIR/redis-server"
echo "======================================================================"
