#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# build_passes_morello.sh — Build LLVM pass plugins on Morello (CheriBSD)
#
# The Morello LLVM cmake config references missing static libraries,
# so we compile passes directly against the LLVM headers instead.
#
# Usage:
#   sh pipeline/build/passes/build_passes_morello.sh [pass_name]
#
# Examples:
#   sh pipeline/build/passes/build_passes_morello.sh                     # build all passes
#   sh pipeline/build/passes/build_passes_morello.sh SealInstrumentationPass  # build one pass
#
# The compiler must be the raw (non-purecap) clang++.
# The system /usr/bin/c++ is a wrapper that adds -march=morello -mabi=purecap,
# which causes LLVM header compilation errors (alignment static_asserts).

set -e

# Defaults match pipeline/set_env.sh — change them THERE, not here. REPO_DIR
# falls back to this script's own location rather than $HOME/capward, since the
# script can always find the checkout it lives in.
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
SRC_DIR="$REPO_DIR/analysis/llvm-passes"
BUILD_DIR="$SRC_DIR/build_morello"

# Use the raw (non-purecap) clang++ from the Morello LLVM toolchain
LLVM_PREFIX="${LLVM_PREFIX:-/usr/local64/llvm-morello}"
LLVM_BIN="${LLVM_BIN:-$LLVM_PREFIX/bin}"
CXX="${CXX:-$LLVM_BIN/clang++}"
CXXFLAGS="${PASS_CXXFLAGS:--fPIC -std=c++17 -O2 -fno-rtti}"
INCLUDES="-I${LLVM_PREFIX}/include"

# All available passes
ALL_PASSES="SealInstrumentationPass CrossCompartmentTypeAnalyzer"

# Which passes to build
if [ $# -gt 0 ]; then
    PASSES="$*"
else
    PASSES="$ALL_PASSES"
fi

mkdir -p "$BUILD_DIR"

for PASS in $PASSES; do
    SRC="$SRC_DIR/${PASS}.cpp"
    OBJ="$BUILD_DIR/${PASS}.o"
    SO="$BUILD_DIR/lib${PASS}.so"

    if [ ! -f "$SRC" ]; then
        echo "ERROR: $SRC not found"
        exit 1
    fi

    echo "=== Building $PASS ==="

    # Step 1: Compile to object file
    echo "  Compiling ${PASS}.cpp ..."
    $CXX $CXXFLAGS $INCLUDES -c -o "$OBJ" "$SRC"

    # Step 2: Link to shared library
    # Link against libLLVM.so to resolve LLVM symbols (FreeBSD dlopen doesn't
    # inherit symbols from the loading process like Linux -rdynamic does)
    echo "  Linking lib${PASS}.so ..."
    $CXX -shared -o "$SO" "$OBJ" -L"${LLVM_PREFIX}/lib" -lLLVM -Wl,-rpath,"${LLVM_PREFIX}/lib"

    echo "  Built: $SO"
    echo ""
done

echo "Done. Pass plugins are in: $BUILD_DIR/"
