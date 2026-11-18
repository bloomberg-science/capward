#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# build_pcre2.sh — Build PCRE2 as a purecap shared library + merged bitcode
#
# Source: $HOME/lib_srcs/pcre2 (v10.42, clean upstream PCRE2Project tarball)
#
# CHERI provenance: there is no CHERI source fork of pcre2. The CheriBSD port
# (cheribsd-ports/devel/pcre2, PORTVERSION 10.42) carries NO CHERI source
# patches — its only purecap-specific action is disabling JIT under the purecap
# ABI (!${ABI:Mpurecap}). PCRE2's sole CHERI incompatibility is its asm JIT
# (sljit), so we simply omit --enable-jit below (JIT is off by default anyway).
# The port's two files/patch-* are generic FreeBSD patches (pkgconfig->libdata
# path; a PPC32 sljit fix) and are irrelevant to this out-of-tree purecap build.
#
# Output: workspace/libraries/pcre2/
#   - libpcre2-8.so         — non-instrumented purecap shared library
#   - pcre2_merged.bc       — merged whole-program bitcode (LTO pre-opt)
#
# Uses -flto + -Wl,-plugin-opt=save-temps: the linker saves the merged
# whole-program bitcode alongside the .so in a single build pass. Run once;
# outputs are shared across all apps that use pcre2 (currently: nginx).

set -e

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

PCRE2_SRC="${PCRE2_SRC:-$HOME/lib_srcs/pcre2}"
WKSP="${WORKSPACE_DIR}/libraries/pcre2"
BUILD_DIR="$PCRE2_SRC/build_purecap"

echo "======================================================================"
echo "Building PCRE2 (purecap) — bitcode + shared library"
echo "Source: ${PCRE2_SRC}"
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
# Step 1: Configure with -flto + save-temps (shared only — pcre2 is its own
# compartment, so it must be a shared library, not folded into the app).
# ============================================================================

echo ">>> Step 1: Configuring PCRE2..."

cd "$BUILD_DIR"

# autoconf decides "am I cross-compiling?" by comparing --build against --host,
# and only then stops trying to RUN the test programs it compiles. Both were
# previously pinned to the target triple, which is right natively but makes a
# Linux host claim it can execute aarch64 binaries — configure then aborts with
# "cannot run C compiled programs". config.guess is not usable as --build
# unconditionally: on CheriBSD it reports aarch64c-unknown-freebsd15.0 (note the
# purecap "c"), which would NOT match --host and would wrongly flip a native
# build into cross mode.
case "$(uname -s)" in
    FreeBSD) PCRE2_BUILD_TRIPLE="aarch64-unknown-freebsd" ;;   # == --host: native
    *)       PCRE2_BUILD_TRIPLE="$(sh "$PCRE2_SRC/config.guess")" ;;
esac

if [ ! -f ".configured_purecap" ]; then
    make -C "$PCRE2_SRC" distclean >/dev/null 2>&1 || true
    # The ABI flags go in CC, not just LDFLAGS: libtool rebuilds the link line
    # and drops -march/-mabi/--sysroot from it, but it always preserves the
    # compiler command. Without them the shared-library link falls back to the
    # hybrid aarch64 ABI and fails on crti.o/crtn.o, which purecap CheriBSD does
    # not ship (they exist only under /usr/lib32 and /usr/lib64). This never bit
    # the native build, where purecap is already the default ABI.
    CC="$CC ${CHERI_LDFLAGS}" \
    CFLAGS="${COMMON_CFLAGS} -flto" \
    LDFLAGS="${CHERI_LDFLAGS} -flto -Wl,-plugin-opt=save-temps" \
    "$PCRE2_SRC/configure" \
        --build="$PCRE2_BUILD_TRIPLE" \
        --host=aarch64-unknown-freebsd \
        --enable-shared \
        `# NOTE: do NOT add --enable-jit — sljit is CHERI-incompatible; the` \
        `# CheriBSD port disables JIT under purecap and so do we (off by default).` \
        --disable-static \
        --enable-pcre2-8 \
        --disable-pcre2grep-libz \
        --disable-pcre2grep-libbz2
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
# libtool builds the versioned .so and its preopt bitcode under .libs/.
# ============================================================================

echo ">>> Step 3: Collecting outputs..."

# Copy the library through libtool's .libs/libpcre2-8.so symlink (cp follows it
# to the real versioned ELF). Do NOT glob 'libpcre2-8.so.*' — that also matches
# the -flto save-temps artifacts (.0.0.preopt.bc, .lto.o, .resolution.txt) and
# can copy a TEXT file (the LTO resolution list) as the "library", which then
# makes downstream linkers choke ("unknown directive: ...").
SO="$BUILD_DIR/.libs/libpcre2-8.so"
PREOPT=$(find "$BUILD_DIR/.libs" -name 'libpcre2-8.so.*.0.0.preopt.bc' | head -1)

if [ ! -e "$SO" ]; then
    echo "ERROR: libpcre2-8.so not built under $BUILD_DIR/.libs" >&2
    exit 1
fi
if [ -z "$PREOPT" ]; then
    echo "ERROR: preopt.bc not found — did -flto save-temps work?" >&2
    find "$BUILD_DIR" -name '*.preopt.bc' >&2
    exit 1
fi

cp "$SO"     "$WKSP/libpcre2-8.so"
cp "$PREOPT" "$WKSP/pcre2_merged.bc"

# Sanity: the copied library must be a real ELF, not a stray text/IR artifact.
if ! file -b "$WKSP/libpcre2-8.so" | grep -q 'ELF'; then
    echo "ERROR: $WKSP/libpcre2-8.so is not an ELF object:" >&2
    file "$WKSP/libpcre2-8.so" >&2
    exit 1
fi

echo "    → $WKSP/libpcre2-8.so"
echo "    → $WKSP/pcre2_merged.bc"

echo "======================================================================"
echo "PCRE2 build complete."
echo "  Library: $WKSP/libpcre2-8.so"
echo "  Bitcode: $WKSP/pcre2_merged.bc"
echo "  Headers: $BUILD_DIR/src/pcre2.h (generated by configure)"
echo "======================================================================"
