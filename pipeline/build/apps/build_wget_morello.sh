#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# build_wget_morello.sh — Build seal-instrumented wget on Morello/CheriBSD
#
# Compartments: wget(0), openssl(1), zlib(2)
# Source: wget 1.21.4
# Deps: openssl, zlib from workspace/libraries/
#
# Bitcode via -flto + -Wl,-plugin-opt=save-temps: wget's own link emits the
# whole-program preopt bitcode (src/wget[.0.0.preopt.bc]). No per-.c collection.

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
# Host-portability fallback; see pipeline/set_env.sh section 6b.
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
# Optimisation level of the ANALYSIS bitcode. Override to experiment, e.g.
#   OPT_FLAGS="-O0 -g" DISTCLEAN=1 sh <this script>
# Keep -g: the analyzer needs debug info to attribute fields to types.
OPT_FLAGS="${OPT_FLAGS:--O2 -g}"
COMMON_CFLAGS="${OPT_FLAGS} ${CHERI_CFLAGS}"

WGET_VERSION="${WGET_VERSION:-1.21.4}"
WGET_SRC="${WGET_SRC:-$HOME/wget-${WGET_VERSION}}"

WKSP="${WORKSPACE_DIR}/wget"
LIB_OPENSSL="${WORKSPACE_DIR}/libraries/openssl"
LIB_ZLIB="${WORKSPACE_DIR}/libraries/zlib"
OPENSSL_SRC="${OPENSSL_SRC:-$HOME/lib_srcs/openssl}"
OPENSSL_BUILD="${OPENSSL_BUILD:-$OPENSSL_SRC/build_purecap}"
ZLIB_SRC="${ZLIB_SRC:-$HOME/lib_srcs/zlib}"

echo "======================================================================"
echo "Building seal-instrumented wget ${WGET_VERSION}"
echo "  Compartments: wget(0) openssl(1) zlib(2)"
echo "======================================================================"

if [ -z "$LINK_ONLY" ]; then

for f in "$LIB_OPENSSL/openssl_merged.bc" "$LIB_OPENSSL/libssl.so" \
         "$LIB_ZLIB/zlib_merged.bc" "$LIB_ZLIB/libz.so"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: $f not found. Run pipeline/build/libraries/build_{openssl,zlib}.sh first." >&2
        exit 1
    fi
done

# ============================================================================
# Step 1: Build wget with -flto + save-temps
# NOTE: openssl/zlib -I/-L paths may need tuning to your Morello layout.
# ============================================================================

echo ">>> Step 1: Building wget (purecap, -flto save-temps)..."

cd "$WGET_SRC"

# DISTCLEAN=1 (set by run_seal_analysis.sh --distclean): force a full recompile.
# Removing the stamp alone only re-runs configure — the objects must go too, or
# make sees them up to date and silently keeps bitcode built with the OLD flags.
# distclean fails if the tree was never configured, hence the `|| true`.
if [ -n "$DISTCLEAN" ]; then
    echo "    DISTCLEAN: gmake distclean + removing the configure stamp"
    gmake distclean >/dev/null 2>&1 || true
    rm -f .configured_purecap_lto
fi

if [ ! -f ".configured_purecap_lto" ]; then
    # autoconf compares --build with --host to decide whether it may RUN the
    # test programs it compiles. Both were pinned to the target triple, which is
    # correct natively but makes a Linux host claim it can execute aarch64
    # FreeBSD binaries; configure then aborts with "cannot run C compiled
    # programs". Naming the real build machine puts it into cross mode.
    case "$(uname -s)" in
        FreeBSD) BUILD_TRIPLE="aarch64-unknown-freebsd" ;;   # == --host: native
        Linux)   BUILD_TRIPLE="$(uname -m)-pc-linux-gnu" ;;
        Darwin)  BUILD_TRIPLE="$(uname -m)-apple-darwin" ;;
        *)       BUILD_TRIPLE="$(uname -m)-unknown-$(uname -s | tr '[:upper:]' '[:lower:]')" ;;
    esac

    # am_cv_func_iconv=no / am_cv_lib_iconv=no: hard-disable gnulib iconv so a
    # GNU converters/libiconv header (/usr/local/include/iconv.h) can't shadow
    # base <iconv.h> and remap calls to undefined libiconv_* symbols.
    # --disable-{iri,nls,pcre2,pcre} + --without-libpsl trim optional deps down
    # to just openssl+zlib (matches a minimal CheriBSD port build).
    #
    # PKG_CONFIG_PATH points wget's PKG_CHECK_MODULES([OPENSSL]) at our purecap
    # 3.0.5 install tree (produced by build_openssl.sh 'make install_dev'), so
    # openssl.c compiles against 3.0.5 headers matching our libssl.so. Without
    # this, pkg-config finds the system OpenSSL 1.1.1v at /usr/local64 and
    # injects -I/usr/local64/include ahead of ours → openssl.c is built against
    # 1.1.1 (where SSL_get_peer_certificate is a real symbol) but linked against
    # 3.0.5 (which only exports SSL_get1_peer_certificate) → undefined symbol.
    # This single consistent -I also retires the old build-dir+source -I split.
    am_cv_func_iconv=no am_cv_lib_iconv=no \
    PKG_CONFIG_PATH="${OPENSSL_BUILD}/install/lib/pkgconfig" \
    CC="$CC" \
    CFLAGS="${COMMON_CFLAGS} -flto -I${ZLIB_SRC}" \
    LDFLAGS="${CHERI_LDFLAGS} -flto -Wl,-plugin-opt=save-temps -L${LIB_OPENSSL} -L${LIB_ZLIB}" \
    ./configure \
        --build="$BUILD_TRIPLE" \
        --host=aarch64-unknown-freebsd \
        --with-ssl=openssl \
        --disable-iri \
        --disable-nls \
        --disable-pcre2 \
        --disable-pcre \
        --without-libpsl
    touch .configured_purecap_lto
fi

# wget's Makefile is automake-generated → requires GNU make (BSD make mis-runs
# the flex/ylwrap rule: "flex -ocss.c" with no input → premature EOF).
gmake -j"$NPROC"

# ============================================================================
# Step 2: Collect bitcode
# ============================================================================

echo ">>> Step 2: Collecting bitcode..."
mkdir -p "$WKSP/bitcode"

PREOPT_BC=$(find "$WGET_SRC/src" -name 'wget.0.0.preopt.bc' 2>/dev/null | head -1)
[ -n "$PREOPT_BC" ] || PREOPT_BC=$(find "$WGET_SRC" -name '*wget*.0.0.preopt.bc' 2>/dev/null | head -1)
if [ -z "$PREOPT_BC" ]; then
    echo "ERROR: wget preopt bitcode not found — did the link succeed with -flto save-temps?" >&2
    find "$WGET_SRC" -name '*.preopt.bc' 2>/dev/null | head >&2
    exit 1
fi

cp "$PREOPT_BC"                     "$WKSP/bitcode/wget_merged.bc"
cp "$LIB_OPENSSL/openssl_merged.bc" "$WKSP/bitcode/openssl_merged.bc"
cp "$LIB_ZLIB/zlib_merged.bc"       "$WKSP/bitcode/zlib_merged.bc"
echo "    → wget_merged.bc, openssl_merged.bc, zlib_merged.bc"

# ============================================================================
# Steps 3-7: Analysis + Instrumentation
# ============================================================================

echo ">>> Running seal pipeline..."
sh "${REPO_DIR}/pipeline/build/seal_pipeline.sh" \
    --app wget \
    --libs "wget:0 openssl:1 zlib:2"

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
    $CC $CHERI_CFLAGS -O2 -flto "$OBJ_DIR/wget${sfx}.bc" \
        -L"$OUT" -lssl_sealed -lz_sealed \
        -lthr \
        -o "$OUT/wget"
}

link_variant ""          "$INSTRUMENTED_DIR"
link_variant "_baseline" "$WKSP/baseline"
echo "    -> instrumented/wget + baseline/wget"

# ============================================================================
# Verify
# ============================================================================

echo ">>> Verification..."
file "$INSTRUMENTED_DIR/wget"
LD_LIBRARY_PATH="$INSTRUMENTED_DIR" "$INSTRUMENTED_DIR/wget" --version 2>&1 || true

echo "======================================================================"
echo "Build complete! Binary: $INSTRUMENTED_DIR/wget"
echo "======================================================================"
