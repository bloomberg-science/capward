#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# build_nginx_morello.sh — Build seal-instrumented nginx on Morello/CheriBSD
#
# Compartments: nginx(0), openssl(1), pcre2(2), zlib(3)
# Source: nginx 1.24.0 — CTSRD-CHERI purecap port
#   github.com/CTSRD-CHERI/nginx, branch release-1.24.0-with-cheri-fixes.
#   (No 1.28 CHERI port exists; the CHERI-adapted line tops out at 1.24.)
#   Cloned to $HOME/nginx-cheri-1.24.0 — override with NGINX_SRC if elsewhere.
# Deps: openssl, pcre2, zlib from workspace/libraries/ (built by pipeline/build/libraries/)
#
# Bitcode is produced with -flto + -Wl,-plugin-opt=save-temps: nginx's own link
# step emits objs/nginx.0.0.preopt.bc — the whole-program nginx compartment,
# including generated files like ngx_modules (which the old per-TU llvm-link
# merge missed). No manual llvm-link, no per-.c bitcode collection.
#
# Prerequisites: run pipeline/build/libraries/build_{openssl,pcre2,zlib}.sh first.

set -e

# --link-only runs ONLY step 8, linking from bitcode already staged in
# workspace/<app>/build/ by seal_pipeline.sh step 7. Steps 1-7 are skipped, so
# nothing is compiled from source and the application and library source trees
# need not be present. Use it to link the published compartment bitcode without
# an emulated from-source build.
LINK_ONLY=""
[ "$1" = "--link-only" ] && { LINK_ONLY=1; shift; }

# Defaults match pipeline/set_env.sh — change them THERE, not here.
REPO_DIR="${REPO_DIR:-$HOME/capward}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$REPO_DIR/workspace}"
# Host-portability fallbacks; see pipeline/set_env.sh section 6b.
NPROC="${NPROC:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"
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
SYSTEM_LIB_DIR="${SYSTEM_LIB_DIR:-/usr/local/lib}"
# Optimisation level of the ANALYSIS bitcode. Override to experiment, e.g.
#   OPT_FLAGS="-O0 -g" DISTCLEAN=1 sh <this script>
# Keep -g: the analyzer needs debug info to attribute fields to types.
OPT_FLAGS="${OPT_FLAGS:--O2 -g}"
COMMON_CFLAGS="${OPT_FLAGS} ${CHERI_CFLAGS}"

NGINX_VERSION="${NGINX_VERSION:-1.24.0}"
# CTSRD-CHERI purecap port lives here (not $HOME/nginx-$NGINX_VERSION, which is
# the vanilla tree). Override NGINX_SRC to point elsewhere.
NGINX_SRC="${NGINX_SRC:-$HOME/nginx-cheri-${NGINX_VERSION}}"

WKSP="${WORKSPACE_DIR}/nginx"
LIB_OPENSSL="${WORKSPACE_DIR}/libraries/openssl"
LIB_PCRE2="${WORKSPACE_DIR}/libraries/pcre2"
LIB_ZLIB="${WORKSPACE_DIR}/libraries/zlib"

# Header locations for the purecap library builds (used by nginx configure).
OPENSSL_SRC="${OPENSSL_SRC:-$HOME/lib_srcs/openssl}"
OPENSSL_BUILD="${OPENSSL_BUILD:-$OPENSSL_SRC/build_purecap}"
PCRE2_SRC="${PCRE2_SRC:-$HOME/lib_srcs/pcre2}"
ZLIB_SRC="${ZLIB_SRC:-$HOME/lib_srcs/zlib}"

echo "======================================================================"
echo "Building seal-instrumented nginx ${NGINX_VERSION}"
echo "  Compartments: nginx(0) openssl(1) pcre2(2) zlib(3)"
echo "======================================================================"

if [ -z "$LINK_ONLY" ]; then

# Verify library prerequisites (produced by pipeline/build/libraries/)
for f in "$LIB_OPENSSL/openssl_merged.bc" "$LIB_OPENSSL/libssl.so" \
         "$LIB_PCRE2/pcre2_merged.bc" "$LIB_PCRE2/libpcre2-8.so" \
         "$LIB_ZLIB/zlib_merged.bc" "$LIB_ZLIB/libz.so"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: $f not found." >&2
        echo "  Run pipeline/build/libraries/build_{openssl,pcre2,zlib}.sh first." >&2
        exit 1
    fi
done

# ============================================================================
# Step 1: Build nginx with -flto + save-temps
#
# nginx passes compile flags via --with-cc-opt and link flags via --with-ld-opt.
# The link must SUCCEED (against the purecap library .so's) for the LTO plugin
# to emit objs/nginx.0.0.preopt.bc.
# NOTE: the -I/-L library paths below may need tuning to your Morello layout.
# ============================================================================

echo ">>> Step 1: Building nginx (purecap, -flto save-temps)..."

cd "$NGINX_SRC"

# DISTCLEAN=1 (set by run_seal_analysis.sh --distclean): force a full recompile.
# Removing the stamp alone only re-runs configure — the objects must go too, or
# make sees them up to date and silently keeps bitcode built with the OLD flags.
if [ -n "$DISTCLEAN" ]; then
    echo "    DISTCLEAN: removing objs/, Makefile and the configure stamp"
    rm -rf objs Makefile
    rm -f .configured_purecap_lto
fi

# CHERI build flags (per the port's README-morello.md):
#   -Wno-cheri-provenance : nginx configure enables -Werror, which promotes
#       benign CHERI pointer-provenance warnings to hard errors. The port
#       documents suppressing them (the warnings are benign here).
#   --without-http_geo_module : http_geo_module casts a pointer *difference*
#       back to a pointer, yielding a non-dereferenceable capability (runtime
#       capability misuse). It's a default module, so it must be disabled.
# NOTE (library compartmentalisation): the README also lists
#   -Xclang -morello-bounded-memargs=caller-only for CheriBSD c18n. We use our
#   own sealing-based compartmentalisation, not c18n, so it is intentionally
#   omitted; add it here if you switch to the c18n model.
# NOTE: the -I/-L library paths below may need tuning to your Morello layout.
if [ ! -f ".configured_purecap_lto" ]; then
    ./auto/configure \
        --with-cc="$CC" \
        --with-cc-opt="${COMMON_CFLAGS} -flto -Wno-cheri-provenance -I${OPENSSL_BUILD}/include -I${OPENSSL_SRC}/include -I${PCRE2_SRC}/build_purecap/src -I${ZLIB_SRC}" \
        --with-ld-opt="${CHERI_CFLAGS} -flto -Wl,-plugin-opt=save-temps -L${LIB_OPENSSL} -L${LIB_PCRE2} -L${LIB_ZLIB}" \
        --without-http_geo_module \
        --with-http_ssl_module \
        --with-pcre \
        --with-compat
    touch .configured_purecap_lto
fi

make -j"$NPROC"

# ============================================================================
# Step 2: Collect bitcode
# ============================================================================

echo ">>> Step 2: Collecting bitcode..."
mkdir -p "$WKSP/bitcode"

PREOPT_BC="$NGINX_SRC/objs/nginx.0.0.preopt.bc"
if [ ! -f "$PREOPT_BC" ]; then
    echo "ERROR: $PREOPT_BC not found — did the link succeed with -flto save-temps?" >&2
    exit 1
fi

cp "$PREOPT_BC"                   "$WKSP/bitcode/nginx_merged.bc"
cp "$LIB_OPENSSL/openssl_merged.bc" "$WKSP/bitcode/openssl_merged.bc"
cp "$LIB_PCRE2/pcre2_merged.bc"     "$WKSP/bitcode/pcre2_merged.bc"
cp "$LIB_ZLIB/zlib_merged.bc"       "$WKSP/bitcode/zlib_merged.bc"
echo "    → nginx_merged.bc (whole nginx compartment, incl. ngx_modules)"
echo "    → openssl_merged.bc, pcre2_merged.bc, zlib_merged.bc (from libraries/)"

# ============================================================================
# Steps 3-7: Analysis + Instrumentation
# ============================================================================

echo ">>> Running seal pipeline..."
sh "${REPO_DIR}/pipeline/build/seal_pipeline.sh" \
    --app nginx \
    --libs "nginx:0 openssl:1 pcre2:2 zlib:3"

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

echo ">>> Step 8: Linking..."

OBJ_DIR="$WKSP/build"
INSTRUMENTED_DIR="$WKSP/instrumented"
mkdir -p "$INSTRUMENTED_DIR"

# $1 = bitcode suffix ("" = sealed | "_baseline"), $2 = output dir.
# codegen happens here via clang -flto (LTO backend in lld); see seal_pipeline.sh step 7.
# nginx.bc is the whole nginx compartment from the LTO save-temps bitcode, so it
# already contains ngx_modules — no separate (un-instrumented) ngx_modules.o
# bolt-on is needed (that was a per-TU-merge artifact).
link_variant() {
    sfx="$1"; OUT="$2"; mkdir -p "$OUT"
    $CC $CHERI_CFLAGS -O2 -flto -shared -Wl,-soname,libssl_sealed.so \
        "$OBJ_DIR/openssl${sfx}.bc" -o "$OUT/libssl_sealed.so"
    $CC $CHERI_CFLAGS -O2 -flto -shared -Wl,-soname,libpcre2_sealed.so \
        "$OBJ_DIR/pcre2${sfx}.bc" -o "$OUT/libpcre2_sealed.so"
    $CC $CHERI_CFLAGS -O2 -flto -shared -Wl,-soname,libz_sealed.so \
        "$OBJ_DIR/zlib${sfx}.bc" -o "$OUT/libz_sealed.so"
    $CC $CHERI_CFLAGS -O2 -flto "$OBJ_DIR/nginx${sfx}.bc" \
        -L"$OUT" -lssl_sealed -lpcre2_sealed -lz_sealed \
        -lthr -lcrypt -L"$SYSTEM_LIB_DIR" -o "$OUT/nginx"
}

link_variant ""          "$INSTRUMENTED_DIR"
link_variant "_baseline" "$WKSP/baseline"
echo "    -> instrumented/nginx + baseline/nginx"

# ============================================================================
# Verify
# ============================================================================

echo ">>> Verification..."
file "$INSTRUMENTED_DIR/nginx"
LD_LIBRARY_PATH="$INSTRUMENTED_DIR" "$INSTRUMENTED_DIR/nginx" -V 2>&1 || true

echo "======================================================================"
echo "Build complete! Binary: $INSTRUMENTED_DIR/nginx"
echo "======================================================================"
