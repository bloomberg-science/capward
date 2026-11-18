#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# build_nghttp2.sh — Build nghttp2 as a purecap shared library + merged bitcode
#
# Source: $HOME/nghttp2-1.55.1 (v1.55.1)
# Output: workspace/libraries/nghttp2/
#   - libnghttp2.so          — non-instrumented purecap shared library
#   - libnghttp2.so.0.0.preopt.bc — merged whole-program bitcode
#
# Uses -flto + -Wl,-plugin-opt=save-temps. Run once; shared across all apps.

set -e

REPO_DIR="${REPO_DIR:-$HOME/capward}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$REPO_DIR/workspace}"
# Host-portability fallback; see pipeline/set_env.sh section 6b.
NPROC="${NPROC:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"
LLVM_PREFIX="${LLVM_PREFIX:-/usr/local64/llvm-morello}"
LLVM_BIN="${LLVM_BIN:-$LLVM_PREFIX/bin}"
CC="${CC:-$LLVM_BIN/clang}"
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
COMMON_CFLAGS="-O2 -g ${CHERI_CFLAGS}"

NGHTTP2_SRC="${NGHTTP2_SRC:-$HOME/nghttp2-1.55.1}"
WKSP="${WORKSPACE_DIR}/libraries/nghttp2"
BUILD_DIR="$NGHTTP2_SRC/build_purecap_flto"

echo "======================================================================"
echo "Building nghttp2 (purecap) — bitcode + shared library"
echo "Source: ${NGHTTP2_SRC}"
echo "Output: ${WKSP}"
echo "======================================================================"

mkdir -p "$WKSP" "$BUILD_DIR"
cd "$BUILD_DIR"

# ============================================================================
# Step 1: Configure and build
# ============================================================================

echo ">>> Step 1: Configuring and building nghttp2..."

if [ ! -f ".configured_purecap_flto" ]; then
    CFLAGS="${COMMON_CFLAGS} -flto" \
    LDFLAGS="${CHERI_LDFLAGS} -flto -Wl,-plugin-opt=save-temps" \
    $CMAKE "$NGHTTP2_SRC" \
        -DCMAKE_C_COMPILER="$CC" \
        -DENABLE_LIB_ONLY=ON \
        -DBUILD_SHARED_LIBS=ON \
        -DBUILD_TESTING=OFF
    touch .configured_purecap_flto
fi

make -j"$NPROC" 2>&1

# ============================================================================
# Step 2: Collect outputs
# ============================================================================

echo ">>> Step 2: Collecting outputs..."

# cmake produces: libnghttp2.so.14.x.y (actual), libnghttp2.so.14 (symlink),
# libnghttp2.so (symlink). The preopt.bc is named after the real versioned file.
SOFILE=$(find "$BUILD_DIR/lib" -name "libnghttp2.so.*.*.*" ! -name "*.bc" \
    ! -name "*.o" ! -name "*.txt" ! -name "*.pc" | head -1)
PREOPT=$(find "$BUILD_DIR/lib" -name "libnghttp2.so.*.*.*.0.0.preopt.bc" | head -1)

if [ -z "$SOFILE" ]; then
    echo "ERROR: versioned libnghttp2.so not found in $BUILD_DIR/lib"
    exit 1
fi
if [ -z "$PREOPT" ]; then
    echo "ERROR: preopt.bc not found — did -flto save-temps work?"
    exit 1
fi

cp "$SOFILE"  "$WKSP/libnghttp2.so"
cp "$PREOPT"  "$WKSP/libnghttp2.so.0.0.preopt.bc"

# The soname embedded in the .so is libnghttp2.so.14 — create a symlink
# so the runtime linker can find it via LD_LIBRARY_PATH.
ln -sf libnghttp2.so "$WKSP/libnghttp2.so.14"

echo "    → $WKSP/libnghttp2.so"
echo "    → $WKSP/libnghttp2.so.14 (symlink)"
echo "    → $WKSP/libnghttp2.so.0.0.preopt.bc"

echo "======================================================================"
echo "nghttp2 build complete."
echo "  Library: $WKSP/libnghttp2.so"
echo "  Bitcode: $WKSP/libnghttp2.so.0.0.preopt.bc"
echo "======================================================================"
