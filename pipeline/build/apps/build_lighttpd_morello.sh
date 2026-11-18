#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# build_lighttpd_morello.sh — Build seal-instrumented lighttpd on Morello/CheriBSD
#
# Compartments: lighttpd(0), openssl(1), zlib(2)
# Source: lighttpd 1.4.71
# Deps: OpenSSL, zlib from workspace/libraries/ (built by pipeline/build/libraries/)
#
# Prerequisites: run pipeline/build/libraries/build_zlib.sh and
#                    pipeline/build/libraries/build_openssl.sh first.

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

LIGHTTPD_VERSION="${LIGHTTPD_VERSION:-1.4.71}"
LIGHTTPD_URL="https://download.lighttpd.net/lighttpd/releases-1.4.x/lighttpd-${LIGHTTPD_VERSION}.tar.gz"
LIGHTTPD_SRC="${LIGHTTPD_SRC:-$HOME/lighttpd-${LIGHTTPD_VERSION}}"

WKSP="${WORKSPACE_DIR}/lighttpd"
LIB_ZLIB="${WORKSPACE_DIR}/libraries/zlib"
LIB_OPENSSL="${WORKSPACE_DIR}/libraries/openssl"
OPENSSL_SRC="${OPENSSL_SRC:-$HOME/lib_srcs/openssl}"
ZLIB_SRC="${ZLIB_SRC:-$HOME/lib_srcs/zlib}"
OPENSSL_BUILD="${OPENSSL_BUILD:-$OPENSSL_SRC/build_purecap}"

echo "======================================================================"
echo "Building seal-instrumented lighttpd ${LIGHTTPD_VERSION}"
echo "======================================================================"

if [ -z "$LINK_ONLY" ]; then

# Verify library prerequisites
for f in "$LIB_ZLIB/libz.so" "$LIB_OPENSSL/libssl.so" "$LIB_OPENSSL/libcrypto.so"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: $f not found. Run pipeline/build/libraries/build_zlib.sh / build_openssl.sh first."
        exit 1
    fi
done

# ============================================================================
# Step 0: Download source if needed
# ============================================================================

if [ ! -d "$LIGHTTPD_SRC" ]; then
    echo ">>> Downloading lighttpd ${LIGHTTPD_VERSION}..."
    cd "$HOME"
    ${DOWNLOAD:-$(command -v fetch >/dev/null 2>&1 && echo fetch || echo "curl -LO")} "$LIGHTTPD_URL"
    tar xzf "lighttpd-${LIGHTTPD_VERSION}.tar.gz"
fi

# ============================================================================
# Step 1: Build lighttpd with -flto + save-temps
# ============================================================================

echo ">>> Step 1: Building lighttpd (purecap, -flto save-temps)..."

# BUILD_STATIC=ON compiles all modules into the binary (no dlopen).
# We point cmake at our own purecap libz.so and libssl.so/libcrypto.so so
# the link succeeds and produces lighttpd.0.0.preopt.bc alongside the binary.
# -Wl,-plugin-opt=save-temps causes the LTO plugin to save the merged
# whole-program bitcode before optimisation — that is our analysis input.

BUILD_DIR="$LIGHTTPD_SRC/build_purecap_static"

# DISTCLEAN=1 (set by run_seal_analysis.sh --distclean): force a full recompile.
# lighttpd builds out of tree, so dropping the build dir removes the cmake cache,
# the objects and the configure stamp together. Keeping any of them would let the
# build silently reuse objects compiled with the OLD flags.
if [ -n "$DISTCLEAN" ]; then
    echo "    DISTCLEAN: removing $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

if [ ! -f ".configured_purecap_static" ]; then
    # Pass compile/link flags via environment variables so they survive
    # cmake's automatic cache-deletion re-runs (which discard -DCMAKE_C_FLAGS).
    CFLAGS="${COMMON_CFLAGS} -flto" \
    LDFLAGS="${CHERI_LDFLAGS} -flto -Wl,-plugin-opt=save-temps" \
    $CMAKE "$LIGHTTPD_SRC" \
        -DCMAKE_C_COMPILER="$CC" \
        -DWITH_OPENSSL=ON \
        -DWITH_ZLIB=ON \
        -DWITH_PCRE2=OFF \
        -DWITH_BZIP2=OFF \
        -DWITH_LUA=OFF \
        -DWITH_WEBDAV_PROPS=OFF \
        -DWITH_WEBDAV_LOCKS=OFF \
        -DBUILD_STATIC=ON \
        -DZLIB_LIBRARY="$LIB_ZLIB/libz.so" \
        -DZLIB_INCLUDE_DIR="$ZLIB_SRC" \
        -DOPENSSL_SSL_LIBRARY="$LIB_OPENSSL/libssl.so" \
        -DOPENSSL_CRYPTO_LIBRARY="$LIB_OPENSSL/libcrypto.so" \
        -DOPENSSL_INCLUDE_DIR="$OPENSSL_BUILD/install/include"
    touch .configured_purecap_static
fi

# Ensure plugin-static.h exists in the cmake binary src dir (build/) before
# make runs. cmake uses add_subdirectory(src build) so the binary dir for
# src/ is build_purecap_static/build/, which is on the include path.
# Without this file lighttpd tries to dlopen modules that are statically
# linked in, causing startup failures.
PLUGIN_STATIC_H="$BUILD_DIR/build/plugin-static.h"
if [ ! -f "$PLUGIN_STATIC_H" ]; then
    echo ">>> Creating plugin-static.h..."
    mkdir -p "$BUILD_DIR/build"
    cat > "$PLUGIN_STATIC_H" << 'EOF'
/* auto-generated - static plugin list for BUILD_STATIC */
PLUGIN_INIT(mod_access)
PLUGIN_INIT(mod_accesslog)
PLUGIN_INIT(mod_ajp13)
PLUGIN_INIT(mod_alias)
PLUGIN_INIT(mod_auth)
PLUGIN_INIT(mod_authn_file)
PLUGIN_INIT(mod_cgi)
PLUGIN_INIT(mod_deflate)
PLUGIN_INIT(mod_dirlisting)
PLUGIN_INIT(mod_evhost)
PLUGIN_INIT(mod_expire)
PLUGIN_INIT(mod_extforward)
PLUGIN_INIT(mod_fastcgi)
PLUGIN_INIT(mod_indexfile)
PLUGIN_INIT(mod_openssl)
PLUGIN_INIT(mod_proxy)
PLUGIN_INIT(mod_redirect)
PLUGIN_INIT(mod_rewrite)
PLUGIN_INIT(mod_rrdtool)
PLUGIN_INIT(mod_scgi)
PLUGIN_INIT(mod_setenv)
PLUGIN_INIT(mod_simple_vhost)
PLUGIN_INIT(mod_sockproxy)
PLUGIN_INIT(mod_ssi)
PLUGIN_INIT(mod_staticfile)
PLUGIN_INIT(mod_status)
PLUGIN_INIT(mod_userdir)
PLUGIN_INIT(mod_vhostdb)
PLUGIN_INIT(mod_webdav)
PLUGIN_INIT(mod_wstunnel)
EOF
fi

make -j"$NPROC" lighttpd 2>&1

# ============================================================================
# Step 2: Collect bitcode
# ============================================================================

echo ">>> Step 2: Collecting bitcode..."
mkdir -p "$WKSP/bitcode"

# The LTO plugin writes lighttpd.0.0.preopt.bc next to the lighttpd binary.
LIGHTTPD_BIN="$BUILD_DIR/build/lighttpd"
PREOPT_BC="${LIGHTTPD_BIN}.0.0.preopt.bc"

if [ ! -f "$PREOPT_BC" ]; then
    echo "ERROR: $PREOPT_BC not found — did the link succeed with -flto save-temps?"
    exit 1
fi

cp "$PREOPT_BC" "$WKSP/bitcode/lighttpd_merged.bc"
echo "    → lighttpd_merged.bc"

# Library bitcodes from the shared library workspace (read-only)
cp "$LIB_OPENSSL/openssl_merged.bc" "$WKSP/bitcode/openssl_merged.bc"
echo "    → openssl_merged.bc"

cp "$LIB_ZLIB/libz.so.0.0.preopt.bc" "$WKSP/bitcode/zlib_merged.bc"
echo "    → zlib_merged.bc"

# ============================================================================
# Steps 3-7: Analysis + Instrumentation
# ============================================================================

echo ">>> Running seal pipeline..."
sh "${REPO_DIR}/pipeline/build/seal_pipeline.sh" \
    --app lighttpd \
    --libs "lighttpd:0 openssl:1 zlib:2"

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

# $1 = bitcode suffix ("" = sealed | "_baseline"), $2 = output dir.
# codegen happens here via clang -flto (LTO backend in lld); see seal_pipeline.sh step 7.
link_variant() {
    sfx="$1"; OUT="$2"; mkdir -p "$OUT"
    $CC $CHERI_CFLAGS -O2 -flto -shared -Wl,-soname,libssl_sealed.so \
        "$OBJ_DIR/openssl${sfx}.bc" -o "$OUT/libssl_sealed.so"
    $CC $CHERI_CFLAGS -O2 -flto -shared -Wl,-soname,libz_sealed.so \
        "$OBJ_DIR/zlib${sfx}.bc" -o "$OUT/libz_sealed.so"
    $CC $CHERI_CFLAGS -O2 -flto \
        "$OBJ_DIR/lighttpd${sfx}.bc" \
        -L"$OUT" -lssl_sealed -lz_sealed \
        -lthr -lcrypt \
        -o "$OUT/lighttpd"
}

link_variant ""          "$INSTRUMENTED_DIR"
link_variant "_baseline" "$WKSP/baseline"
echo "    -> instrumented/lighttpd + baseline/lighttpd"

# ============================================================================
# Verify
# ============================================================================

echo ">>> Verification..."
file "$INSTRUMENTED_DIR/lighttpd"
LD_LIBRARY_PATH="$INSTRUMENTED_DIR" "$INSTRUMENTED_DIR/lighttpd" -v 2>&1 || true

echo "======================================================================"
echo "Build complete! Binary: $INSTRUMENTED_DIR/lighttpd"
echo "======================================================================"
