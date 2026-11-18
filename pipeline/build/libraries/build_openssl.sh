#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# build_openssl.sh — Build OpenSSL as purecap shared libraries + merged bitcode
#
# Source: $HOME/lib_srcs/openssl (v3.0.5)
# Output: workspace/libraries/openssl/
#   - libssl.so, libcrypto.so       — non-instrumented purecap shared libraries
#   - libssl.so.0.0.preopt.bc       — merged bitcode for libssl
#   - libcrypto.so.0.0.preopt.bc    — merged bitcode for libcrypto
#
# Uses -flto + -Wl,-plugin-opt=save-temps to produce the .so and merged
# bitcode in a single build pass. Run once; outputs are shared across all apps.

set -e

REPO_DIR="${REPO_DIR:-$HOME/capward}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$REPO_DIR/workspace}"
# Host-portability fallback; see pipeline/set_env.sh section 6b.
NPROC="${NPROC:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"
LLVM_PREFIX="${LLVM_PREFIX:-/usr/local64/llvm-morello}"
LLVM_BIN="${LLVM_BIN:-$LLVM_PREFIX/bin}"
CC="${CC:-$LLVM_BIN/clang}"

# Optimisation level of the ANALYSIS bitcode — see the app build scripts.
OPT_FLAGS="${OPT_FLAGS:--O2 -g}"
CHERI_TARGET="${CHERI_TARGET:-aarch64-unknown-freebsd15.0}"
SYSROOT="${SYSROOT:-/}"
SYSTEM_INCLUDE_DIR="${SYSTEM_INCLUDE_DIR:-/usr/include}"
# OpenSSL Configure needs the triple spelled out; the other trees infer it.
CHERI_CFLAGS="-target ${CHERI_TARGET} -march=morello -mabi=purecap ${OPT_FLAGS} --sysroot=${SYSROOT} -isystem ${SYSTEM_INCLUDE_DIR} -I${SYSTEM_INCLUDE_DIR}"
CHERI_LDFLAGS="${CHERI_LDFLAGS:--target $CHERI_TARGET -march=morello -mabi=purecap --sysroot=$SYSROOT}"

OPENSSL_SRC="${OPENSSL_SRC:-$HOME/lib_srcs/openssl}"
OPENSSL_BUILD="${OPENSSL_BUILD:-$OPENSSL_SRC/build_purecap}"
WKSP="${WORKSPACE_DIR}/libraries/openssl"
BUILD_DIR="$OPENSSL_BUILD"

echo "======================================================================"
echo "Building OpenSSL (purecap) — bitcode + shared libraries"
echo "Source: ${OPENSSL_SRC}"
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
# Step 1: Configure
# ============================================================================

echo ">>> Step 1: Configuring OpenSSL..."

cd "$BUILD_DIR"

if [ ! -f ".configured_purecap" ]; then
    "$OPENSSL_SRC/Configure" BSD-generic64 \
        --prefix="$BUILD_DIR/install" \
        no-asm \
        no-tests \
        shared \
        CC="$CC" \
        CFLAGS="$CHERI_CFLAGS -flto" \
        LDFLAGS="${CHERI_LDFLAGS} -flto -Wl,-plugin-opt=save-temps"
    touch .configured_purecap
fi

# ============================================================================
# Step 2: Build
# ============================================================================

echo ">>> Step 2: Building..."
make -j"$NPROC" 2>&1

# ----------------------------------------------------------------------------
# Step 2b: Install a self-consistent dev tree (headers + libs + pkg-config)
# into $BUILD_DIR/install (the configured --prefix; NOT the system).
#
# Why: OpenSSL's out-of-tree build scatters public headers across the build dir
# (generated) and the source tree (static), and never assembles a single
# complete set. install_dev collects them into one consistent 3.0.5 include
# tree and writes correct *.pc files. Consumers (wget/curl/lighttpd) then find
# our 3.0.5 via PKG_CONFIG_PATH instead of the system 1.1.1v at /usr/local64.
# install_dev depends on install_runtime_libs, so libssl.so/libcrypto.so land
# under install/lib too. Prefix is $BUILD_DIR/install → nothing touches /usr.
# ----------------------------------------------------------------------------
echo ">>> Step 2b: Installing dev tree (headers + libs + pkgconfig) to $BUILD_DIR/install ..."
make install_dev 2>&1

# ============================================================================
# Step 3: Copy outputs
# ============================================================================

echo ">>> Step 3: Collecting outputs..."

# OpenSSL produces versioned .so files (libssl.so.3, libcrypto.so.3) and
# correspondingly versioned preopt bitcode files.
cp "$BUILD_DIR/libssl.so.3"                  "$WKSP/libssl.so"
cp "$BUILD_DIR/libcrypto.so.3"               "$WKSP/libcrypto.so"
cp "$BUILD_DIR/libssl.so.3.0.0.preopt.bc"    "$WKSP/libssl.so.0.0.preopt.bc"
cp "$BUILD_DIR/libcrypto.so.3.0.0.preopt.bc" "$WKSP/libcrypto.so.0.0.preopt.bc"

echo "    → $WKSP/libssl.so"
echo "    → $WKSP/libcrypto.so"
echo "    → $WKSP/libssl.so.0.0.preopt.bc"
echo "    → $WKSP/libcrypto.so.0.0.preopt.bc"

# ============================================================================
# Step 4: Merge libssl + libcrypto into a single openssl_merged.bc
# ============================================================================

echo ">>> Step 4: Merging libssl + libcrypto bitcode..."

LLVM_LINK="${LLVM_LINK:-$LLVM_BIN/llvm-link}"

# libssl depends on libcrypto; --override lets libssl definitions take
# precedence where symbols appear in both modules.
"$LLVM_LINK" \
    "$WKSP/libssl.so.0.0.preopt.bc" \
    --override "$WKSP/libcrypto.so.0.0.preopt.bc" \
    -o "$WKSP/openssl_merged.bc"

echo "    → $WKSP/openssl_merged.bc"

echo "======================================================================"
echo "OpenSSL build complete."
echo "======================================================================"
