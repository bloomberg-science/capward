#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# build_libevent.sh — Build libevent as a purecap shared library + merged bitcode
#
# Source: $HOME/lib_srcs/libevent (v2.1.12-stable)
# Output: workspace/libraries/libevent/
#   - libevent.so              — non-instrumented purecap shared library (main)
#   - libevent_merged.bc       — merged whole-program bitcode (all libevent targets)
#
# Uses -flto + -Wl,-plugin-opt=save-temps to produce the .so and per-target
# preopt bitcode in a single CMake build pass. The preopt .bc files are then
# merged with llvm-link into a single libevent_merged.bc used by the analysis
# and instrumentation pipeline. Run once; outputs are shared across all apps
# that use libevent (currently: memcached).

set -e

REPO_DIR="${REPO_DIR:-$HOME/capward}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$REPO_DIR/workspace}"
# Host-portability fallbacks; see pipeline/set_env.sh section 6b.
NPROC="${NPROC:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"
LLVM_PREFIX="${LLVM_PREFIX:-/usr/local64/llvm-morello}"
LLVM_BIN="${LLVM_BIN:-$LLVM_PREFIX/bin}"
CC="${CC:-$LLVM_BIN/clang}"
LLVM_LINK="${LLVM_LINK:-$LLVM_BIN/llvm-link}"
CMAKE="${CMAKE:-/usr/local64/bin/cmake}"

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

LIBEVENT_VERSION="${LIBEVENT_VERSION:-2.1.12-stable}"
LIBEVENT_URL="https://github.com/libevent/libevent/releases/download/release-${LIBEVENT_VERSION}/libevent-${LIBEVENT_VERSION}.tar.gz"
LIBEVENT_SRC="${LIBEVENT_SRC:-$HOME/lib_srcs/libevent}"
WKSP="${WORKSPACE_DIR}/libraries/libevent"
BUILD_DIR="$LIBEVENT_SRC/build_purecap"

echo "======================================================================"
echo "Building libevent ${LIBEVENT_VERSION} (purecap) — bitcode + shared library"
echo "Source: ${LIBEVENT_SRC}"
echo "Output: ${WKSP}"
echo "======================================================================"

# DISTCLEAN=1 (set by run_seal_analysis.sh --distclean): force a full recompile.
# This library builds out of tree, so dropping the build dir removes the configure
# stamp and the objects together. Removing the stamp alone would only re-run
# configure — make would still see the objects up to date and silently keep
# bitcode built with the OLD flags.
if [ -n "$DISTCLEAN" ]; then
    echo "    DISTCLEAN: removing $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi

mkdir -p "$WKSP" "$BUILD_DIR"

# ============================================================================
# Step 0: Download source if needed
# ============================================================================

if [ ! -f "$LIBEVENT_SRC/CMakeLists.txt" ]; then
    echo ">>> Downloading libevent ${LIBEVENT_VERSION}..."
    # The source tree's parent, so an overridden LIBEVENT_SRC downloads beside
    # itself rather than into a fixed $HOME/lib_srcs.
    LIB_SRCS_DIR="$(dirname "$LIBEVENT_SRC")"
    mkdir -p "$LIB_SRCS_DIR"
    cd "$LIB_SRCS_DIR"
    # fetch(1) is FreeBSD/CheriBSD only; curl elsewhere. Direct first, then
    # retry through HTTP_PROXY_URL if one is configured.
    DL="${DOWNLOAD:-$(command -v fetch >/dev/null 2>&1 && echo fetch || echo "curl -LO")}"
    $DL "$LIBEVENT_URL" || \
        { [ -n "${HTTP_PROXY_URL:-}" ] && \
          env http_proxy="$HTTP_PROXY_URL" https_proxy="$HTTP_PROXY_URL" \
              $DL "$LIBEVENT_URL"; }
    tar xzf "libevent-${LIBEVENT_VERSION}.tar.gz"
    mv "libevent-${LIBEVENT_VERSION}" "$(basename "$LIBEVENT_SRC")"
fi

# ============================================================================
# Step 1: Configure with CMake
#
# -flto: compile to bitcode; linker performs LTO and produces native code.
# -Wl,-plugin-opt=save-temps: instructs the LTO plugin to save the merged
# pre-optimisation bitcode file (*.0.0.preopt.bc) alongside each output .so.
# This is what we feed to the cross-compartment analysis and instrumentation.
# ============================================================================

echo ">>> Step 1: Configuring libevent (CMake)..."

cd "$BUILD_DIR"

if [ ! -f ".configured_purecap" ]; then
    $CMAKE "$LIBEVENT_SRC" \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_C_FLAGS="${COMMON_CFLAGS} -flto" \
        -DCMAKE_SHARED_LINKER_FLAGS="${CHERI_LDFLAGS} -flto -Wl,-plugin-opt=save-temps" \
        -DCMAKE_INSTALL_PREFIX="$WKSP" \
        -DEVENT__DISABLE_TESTS=ON \
        -DEVENT__DISABLE_SAMPLES=ON \
        -DEVENT__DISABLE_BENCHMARK=ON \
        -DEVENT__DISABLE_REGRESS=ON \
        `# Base-system OpenSSL, which libevent_openssl links against. Derived` \
        `# from SYSROOT so it stays /usr natively and follows the sysroot when` \
        `# cross-compiling; otherwise find_package(OpenSSL) searches the HOST` \
        `# and fails with "missing: OPENSSL_CRYPTO_LIBRARY OPENSSL_INCLUDE_DIR".` \
        -DOPENSSL_ROOT_DIR="${SYSROOT%/}/usr" \
        `# Confine CMake's find_* to the sysroot for libraries and headers, but` \
        `# let it still find executables on the build machine.` \
        -DCMAKE_FIND_ROOT_PATH="$SYSROOT" \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
        -DBUILD_SHARED_LIBS=ON
    touch .configured_purecap
fi

# ============================================================================
# Step 2: Build
# ============================================================================

echo ">>> Step 2: Building..."
make -j"$NPROC" 2>&1

# ============================================================================
# Step 3: Collect outputs
#
# libevent produces several shared libraries per CMake build:
#   libevent-2.1.so.7.0.1          — core + extra (main combined target)
#   libevent_core-2.1.so.7.0.1     — core only
#   libevent_extra-2.1.so.7.0.1    — extra protocols
#   libevent_openssl-2.1.so.7.0.1  — OpenSSL integration
#   libevent_pthreads-2.1.so.7.0.1 — threading support
#
# We copy the main .so for runtime linking and collect all preopt bitcode files
# for the analysis pipeline.
# ============================================================================

echo ">>> Step 3: Installing to workspace (headers + libraries)..."

# Install puts include/ and lib/ into $WKSP, giving other scripts a clean
# --with-libevent=$WKSP prefix that configure scripts understand.
make install 2>&1
echo "    → $WKSP/include/ (headers)"
echo "    → $WKSP/lib/ (shared libraries)"

# ============================================================================
# Step 4: Merge all preopt bitcode into libevent_merged.bc
#
# Each .so produces its own *.0.0.preopt.bc alongside it in the build dir.
# We merge all of them into a single libevent_merged.bc so the analysis
# sees the full library symbol space in one module.
# ============================================================================

echo ">>> Step 4: Merging libevent bitcode..."

LIBDIR="$BUILD_DIR/lib"

# libevent-2.1.so is the combined library (= libevent_core + libevent_extra).
# Merging core/extra separately would cause duplicate symbol errors.
# libevent_openssl and libevent_pthreads have unique symbols so they can be
# added with --override to let the combined library take precedence on any
# accidental overlap.

MAIN_BC="$LIBDIR/libevent-2.1.so.7.0.1.0.0.preopt.bc"
if [ ! -f "$MAIN_BC" ]; then
    echo "ERROR: Main libevent preopt bitcode not found: $MAIN_BC"
    echo "  Check that -Wl,-plugin-opt=save-temps is supported by this clang/linker."
    exit 1
fi
echo "    found: libevent-2.1.so.7.0.1.0.0.preopt.bc"

OVERRIDE_FLAGS=""
for so in "libevent_openssl-2.1.so.7.0.1" "libevent_pthreads-2.1.so.7.0.1"; do
    bc="$LIBDIR/${so}.0.0.preopt.bc"
    if [ -f "$bc" ]; then
        OVERRIDE_FLAGS="$OVERRIDE_FLAGS --override=$bc"
        echo "    found: ${so}.0.0.preopt.bc"
    else
        echo "    warning: missing ${so}.0.0.preopt.bc (skipping)"
    fi
done

$LLVM_LINK "$MAIN_BC" $OVERRIDE_FLAGS -o "$WKSP/libevent_merged.bc"
echo "    → $WKSP/libevent_merged.bc"

echo "======================================================================"
echo "libevent build complete."
echo "  Library: $WKSP/libevent.so"
echo "  Bitcode: $WKSP/libevent_merged.bc"
echo ""
echo "To use in the analysis pipeline, copy libevent_merged.bc into"
echo "workspace/<app>/bitcode/ for each app that uses libevent."
echo "======================================================================"
