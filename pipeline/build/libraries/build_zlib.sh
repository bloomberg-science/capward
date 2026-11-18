#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# build_zlib.sh — Build zlib as a purecap shared library + merged bitcode
#
# Source: FreeBSD base system zlib (/usr/src/sys/contrib/zlib, v1.3.1)
# Output: workspace/libraries/zlib/
#   - libz.so              — non-instrumented purecap shared library
#   - libz.so.0.0.preopt.bc — merged whole-program bitcode (pre-LTO-opt),
#                             used as read-only input for instrumentation
#
# Uses -flto + -Wl,-plugin-opt=save-temps: the linker saves the merged
# bitcode alongside the .so in a single build pass, with full purecap
# support. Run once; outputs are shared across all apps.

set -e

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

ZLIB_SRC="${ZLIB_SRC:-$HOME/lib_srcs/zlib}"
WKSP="${WORKSPACE_DIR}/libraries/zlib"

echo "======================================================================"
echo "Building zlib (purecap) — bitcode + shared library"
echo "Source: ${ZLIB_SRC}"
echo "Output: ${WKSP}"
echo "======================================================================"

mkdir -p "$WKSP"

# Compile and link in one step using -flto.
# -Wl,-plugin-opt=save-temps instructs the LTO plugin to save intermediate
# bitcode files next to the output. The file libz.so.0.0.preopt.bc is the
# merged whole-program bitcode before LTO optimisations — this is what we
# use for our cross-compartment analysis and instrumentation.

echo ">>> Building libz.so with -flto (save-temps)..."

# -DHAVE_UNISTD_H -DHAVE_STDARG_H do what zlib's own ./configure would do by
# rewriting zconf.h. This script compiles the sources directly and never runs
# that configure, so on a pristine source tree zconf.h leaves Z_HAVE_UNISTD_H
# undefined, gzread.c/gzwrite.c never see <unistd.h>, and the build dies on
# implicit declarations of read/write/close. It went unnoticed because the
# tree it was developed against had been through ./configure already.
$CC $COMMON_CFLAGS -flto -fPIC -shared \
    -DHAVE_UNISTD_H -DHAVE_STDARG_H \
    -Wl,-soname,libz.so \
    -Wl,-plugin-opt=save-temps \
    -I"$ZLIB_SRC" \
    "$ZLIB_SRC"/adler32.c \
    "$ZLIB_SRC"/compress.c \
    "$ZLIB_SRC"/crc32.c \
    "$ZLIB_SRC"/deflate.c \
    "$ZLIB_SRC"/gzclose.c \
    "$ZLIB_SRC"/gzlib.c \
    "$ZLIB_SRC"/gzread.c \
    "$ZLIB_SRC"/gzwrite.c \
    "$ZLIB_SRC"/infback.c \
    "$ZLIB_SRC"/inffast.c \
    "$ZLIB_SRC"/inflate.c \
    "$ZLIB_SRC"/inftrees.c \
    "$ZLIB_SRC"/trees.c \
    "$ZLIB_SRC"/uncompr.c \
    "$ZLIB_SRC"/zutil.c \
    -o "$WKSP/libz.so" 2>&1

echo "    → $WKSP/libz.so"
echo "    → $WKSP/libz.so.0.0.preopt.bc"

# Canonical name expected by the pipeline: workspace/libraries/<lib>/<lib>_merged.bc
# (matches openssl's openssl_merged.bc). Apps copy this into their bitcode dir.
cp "$WKSP/libz.so.0.0.preopt.bc" "$WKSP/zlib_merged.bc"
echo "    → $WKSP/zlib_merged.bc"

echo "======================================================================"
echo "zlib build complete."
echo "  Library: $WKSP/libz.so"
echo "  Bitcode: $WKSP/zlib_merged.bc"
echo "======================================================================"
