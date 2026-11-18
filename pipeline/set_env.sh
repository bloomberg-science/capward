#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# set_env.sh — Central environment for every capward script.
#
# SOURCE this (do not execute) so the exports apply to your shell:
#   . pipeline/set_env.sh            # set + print validation report
#   . pipeline/set_env.sh --quiet    # set, no report
#
# THIS FILE IS THE SINGLE PLACE TO CHANGE A PATH. Every build, test and
# benchmark script in the repository honours these variables and falls back to
# the SAME default if one is unset, so a script still runs standalone — but if
# you need to move something, change it here (or export it before sourcing)
# rather than editing the script that consumes it:
#
#   REPO_DIR=/path/to/capward . pipeline/set_env.sh
#   OPENSSL_SRC=/scratch/openssl . pipeline/set_env.sh
#
# Nothing below is an absolute path except the handful of genuine system
# locations at the top of each section (the LLVM toolchain, cmake, ab, and the
# base CheriBSD utilities). Everything else is derived from those, so overriding
# a parent moves all of its children with it — overriding OPENSSL_SRC moves
# OPENSSL_BUILD and OSSL, overriding LLVM_PREFIX moves CC, CXX, OPT and
# LLVM_LINK, overriding REPO_DIR moves WORKSPACE_DIR.
#
# CRUCIAL: read the printed report and confirm every path is correct BEFORE
# running any pipeline script. Wrong paths are the easiest way to silently build
# against the wrong sources and produce a mess.

# ============================================================================
# 1. Core locations
# ============================================================================
export REPO_DIR="${REPO_DIR:-$HOME/capward}"

# All generated artifacts — bitcode, manifests, instrumented binaries, benchmark
# output. Kept separate from REPO_DIR so it can be pointed at a scratch volume;
# every script derives its own subdirectory from this one variable.
export WORKSPACE_DIR="${WORKSPACE_DIR:-$REPO_DIR/workspace}"

# ============================================================================
# 2. Morello LLVM toolchain
# ============================================================================
# LLVM_PREFIX is the root; everything else in this section derives from it, so
# pointing it at another toolchain moves the compiler, the linker, the pass
# plugins' headers and the purecap builds together.
export LLVM_PREFIX="${LLVM_PREFIX:-/usr/local64/llvm-morello}"
export LLVM_BIN="${LLVM_BIN:-$LLVM_PREFIX/bin}"
export CC="${CC:-$LLVM_BIN/clang}"
export CXX="${CXX:-$LLVM_BIN/clang++}"
export OPT="${OPT:-$LLVM_BIN/opt}"
export LLVM_LINK="${LLVM_LINK:-$LLVM_BIN/llvm-link}"
export CMAKE="${CMAKE:-/usr/local64/bin/cmake}"

# Note that CC and CXX are exported, so anything you build in this shell after
# sourcing picks up the Morello toolchain. That is what the build scripts want;
# use a separate shell for unrelated native builds.
#
# Optimisation level for every purecap compartment build. Changing this requires
# a --distclean: the configure stamps hide a flag-only change from `make`.
export OPT_FLAGS="${OPT_FLAGS:--O2 -g}"

# Base-system locations the purecap builds link and include against. Split out
# so a cross-build against a sysroot elsewhere only has to override these.
# Declared BEFORE CHERI_CFLAGS because that is composed from them.
export SYSROOT="${SYSROOT:-/}"
export SYSTEM_INCLUDE_DIR="${SYSTEM_INCLUDE_DIR:-/usr/include}"
export SYSTEM_LIB_DIR="${SYSTEM_LIB_DIR:-/usr/local/lib}"
export CHERI_TARGET="${CHERI_TARGET:-aarch64-unknown-freebsd15.0}"

# Purecap target flags, shared by every library and application build.
#
# Composed from the four variables above rather than hardcoded, so that
# repointing SYSROOT at a cross-compilation sysroot moves every compartment
# build with it. Natively on CheriBSD these expand to what the compiler would
# have chosen anyway (the native triple, --sysroot=/), so the flags are inert
# there and load-bearing only when cross-compiling from Linux or macOS.
#
# The triple is explicit for every tree now, not just OpenSSL's Configure:
# a cross clang defaults to the HOST triple, so omitting it silently builds
# x86-64 objects instead of failing.
export CHERI_CFLAGS="${CHERI_CFLAGS:--target $CHERI_TARGET -march=morello -mabi=purecap --sysroot=$SYSROOT -isystem $SYSTEM_INCLUDE_DIR}"

# The same story for linking. A link driven by a cross clang without -target
# defaults to the HOST target, and lld then rejects the (correct) purecap
# objects with "is incompatible with elf64-x86-64". No -isystem here: it is a
# compile-only flag and clang warns that it is unused when linking.
export CHERI_LDFLAGS="${CHERI_LDFLAGS:--target $CHERI_TARGET -march=morello -mabi=purecap --sysroot=$SYSROOT}"

# ============================================================================
# 3. Library sources (conventionally under $HOME/lib_srcs)
# ============================================================================
export OPENSSL_SRC="${OPENSSL_SRC:-$HOME/lib_srcs/openssl}"
export ZLIB_SRC="${ZLIB_SRC:-$HOME/lib_srcs/zlib}"
export PCRE2_SRC="${PCRE2_SRC:-$HOME/lib_srcs/pcre2}"
export LIBEVENT_SRC="${LIBEVENT_SRC:-$HOME/lib_srcs/libevent}"

export NGHTTP2_VERSION="${NGHTTP2_VERSION:-1.55.1}"
export NGHTTP2_SRC="${NGHTTP2_SRC:-$HOME/nghttp2-$NGHTTP2_VERSION}"

# OpenSSL's purecap build tree and its install lib directory. Several benchmark
# runners need the shared objects on LD_LIBRARY_PATH; they take OSSL from here
# instead of reconstructing the path, so OPENSSL_SRC stays authoritative.
export OPENSSL_BUILD="${OPENSSL_BUILD:-$OPENSSL_SRC/build_purecap}"
export OSSL="${OSSL:-$OPENSSL_BUILD/install/lib}"

# ============================================================================
# 4. Application sources — the six evaluated applications
# ============================================================================
export NGINX_VERSION="${NGINX_VERSION:-1.24.0}"
export REDIS_VERSION="${REDIS_VERSION:-7.0.12}"
export WGET_VERSION="${WGET_VERSION:-1.21.4}"
export CURL_VERSION="${CURL_VERSION:-8.2.1}"
export MEMCACHED_VERSION="${MEMCACHED_VERSION:-1.6.21}"
export LIGHTTPD_VERSION="${LIGHTTPD_VERSION:-1.4.71}"

export NGINX_SRC="${NGINX_SRC:-$HOME/nginx-cheri-$NGINX_VERSION}"
export REDIS_SRC="${REDIS_SRC:-$HOME/redis-$REDIS_VERSION}"
export WGET_SRC="${WGET_SRC:-$HOME/wget-$WGET_VERSION}"
export CURL_SRC="${CURL_SRC:-$HOME/curl-$CURL_VERSION}"
export MEMCACHED_SRC="${MEMCACHED_SRC:-$HOME/memcached-$MEMCACHED_VERSION}"
export LIGHTTPD_SRC="${LIGHTTPD_SRC:-$HOME/lighttpd-$LIGHTTPD_VERSION}"

# ============================================================================
# 5. Test clients
# ============================================================================
# redis-cli, used by the redis smoke test.
export REDIS_CLI="${REDIS_CLI:-$REDIS_SRC/src/redis-cli}"

# ============================================================================
# 5b. Benchmark runtimes and clients (macrobenchmarks/, microbenchmarks/)
# ============================================================================
# The heap-compartmentalization measurements compare a stock rtld + libc against
# a heap-compartmentalized jemalloc build. Neither runtime is part of this
# repository; each is a directory containing ld-elf.so.1 and libc.so.7.
export BASELINE_LIBC="${BASELINE_LIBC:-$HOME/libc.baseline}"
export MODIFIED_LIBC="${MODIFIED_LIBC:-$HOME/libc.modified.perarena}"

# Benchmark clients always run on the stock system runtime; only the server
# under test is wrapped by the modified rtld + libc.
export AB="${AB:-/usr/local64/bin/ab}"
export REDIS_BENCHMARK="${REDIS_BENCHMARK:-$REDIS_SRC/src/redis-benchmark}"
# Peak-RSS measurement for the microbenchmark.
export TIME_CMD="${TIME_CMD:-/usr/bin/time -l}"

# ============================================================================
# 6. Functional-test tools (base CheriBSD)
# ============================================================================
export FETCH="${FETCH:-/usr/bin/fetch}"
export NC="${NC:-/usr/bin/nc}"
# The system openssl(1) CLI, used by the smoke tests to probe TLS. Distinct from
# OPENSSL_SRC, which is the purecap library we compartmentalize against.
export OPENSSL_BIN="${OPENSSL_BIN:-/usr/bin/openssl}"

# nginx's upstream test suite, cloned separately; test_nginx.sh skips if absent.
export NGINX_TESTS="${NGINX_TESTS:-$HOME/nginx-tests}"

# ============================================================================
# 6b. Host portability
# ============================================================================
# The build scripts run natively on CheriBSD — under QEMU that is Tier 3 of
# ARTIFACT-EVALUATION.md — but they are also cross-capable from Linux or macOS
# (see "Optional: building on the host"). These two cover the base-system
# commands that differ across those hosts.

# Parallelism for make(1). sysctl on BSD/macOS, nproc on Linux.
export NPROC="${NPROC:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"

# Downloader: fetch(1) is FreeBSD/CheriBSD only.
if [ -z "${DOWNLOAD:-}" ]; then
    if command -v fetch >/dev/null 2>&1;   then DOWNLOAD="fetch"
    elif command -v curl >/dev/null 2>&1;  then DOWNLOAD="curl -LO"
    else                                        DOWNLOAD="wget"
    fi
fi
export DOWNLOAD

# ============================================================================
# 7. Test endpoints
# ============================================================================
# The wget/curl functional tests fetch real URLs. Empty proxy = direct
# connection; set this only if your network requires one.
export HTTP_PROXY_URL="${HTTP_PROXY_URL:-}"

# Shared defaults, then per-tool overrides that fall back to them — so one
# change here moves both tools, but either can still be pointed elsewhere.
export TEST_HTTP_URL="${TEST_HTTP_URL:-http://example.com/}"
export TEST_HTTPS_URL="${TEST_HTTPS_URL:-https://example.com/}"
export TEST_GZIP_URL="${TEST_GZIP_URL:-https://www.gnu.org/}"

export WGET_HTTP_URL="${WGET_HTTP_URL:-$TEST_HTTP_URL}"
export WGET_HTTPS_URL="${WGET_HTTPS_URL:-$TEST_HTTPS_URL}"
export WGET_GZIP_URL="${WGET_GZIP_URL:-$TEST_GZIP_URL}"
export CURL_HTTP_URL="${CURL_HTTP_URL:-$TEST_HTTP_URL}"
export CURL_HTTPS_URL="${CURL_HTTPS_URL:-$TEST_HTTPS_URL}"
export CURL_GZIP_URL="${CURL_GZIP_URL:-$TEST_GZIP_URL}"

# ============================================================================
# 8. Ports
# ============================================================================
# Functional tests (sequential, so reuse is safe, but each is overridable).
export NGINX_SMOKE_PORT="${NGINX_SMOKE_PORT:-7721}"
export LIGHTTPD_SMOKE_PORT="${LIGHTTPD_SMOKE_PORT:-7731}"
export MEMCACHED_SMOKE_PORT="${MEMCACHED_SMOKE_PORT:-7732}"
export REDIS_SMOKE_PORT="${REDIS_SMOKE_PORT:-7711}"
export LIGHTTPD_TEST_PORT="${LIGHTTPD_TEST_PORT:-7741}"
export MEMCACHED_TEST_PORT="${MEMCACHED_TEST_PORT:-7799}"

# Benchmark servers (macrobenchmarks/).
export NGINX_HTTP_PORT="${NGINX_HTTP_PORT:-8088}"
export NGINX_HTTPS_PORT="${NGINX_HTTPS_PORT:-8443}"
export LIGHTTPD_HTTP_PORT="${LIGHTTPD_HTTP_PORT:-8089}"
export LIGHTTPD_HTTPS_PORT="${LIGHTTPD_HTTPS_PORT:-8444}"
export REDIS_BENCH_PORT="${REDIS_BENCH_PORT:-6399}"

# ============================================================================
# 9. Benchmark run parameters
# ============================================================================
# Not exported: they are per-invocation. Pass them on the command line:
#
#   REPS   repetitions per configuration
#   NREQ   ab requests per measurement (nginx, lighttpd)
#   NOPS   redis-benchmark operations per measurement (default 100000)
#   OUT    output directory (default under $WORKSPACE_DIR)
#
# The data in results/macrobenchmarks/raw/ was produced with:
#
#   REPS=10 NREQ=50000 sh macrobenchmarks/sealing/run_sealing_matrix.sh
#   REPS=10 NREQ=50000 sh macrobenchmarks/calloc/run_paper_matrix.sh nginx lighttpd
#   REPS=5             sh macrobenchmarks/calloc/run_paper_matrix.sh redis

# ============================================================================
# Validation report
# ============================================================================

if [ "$1" = "--quiet" ]; then
    return 0 2>/dev/null || exit 0
fi

_ce_reqmiss=0
_ce_optmiss=0

_ce_check() {   # $1=req|opt  $2=label  $3=path
    if [ -e "$3" ]; then
        printf '  [ ok  ] %-14s %s\n' "$2" "$3"
    elif [ "$1" = req ]; then
        printf '  [MISS!] %-14s %s   <-- REQUIRED\n' "$2" "$3"
        _ce_reqmiss=$((_ce_reqmiss + 1))
    else
        printf '  [ --  ] %-14s %s\n' "$2" "$3"
        _ce_optmiss=$((_ce_optmiss + 1))
    fi
}

echo "======================================================================"
echo "capward environment — validation report"
echo "======================================================================"

echo "Core (required):"
_ce_check req REPO_DIR        "$REPO_DIR"
_ce_check req "capward"       "$REPO_DIR/pipeline"
_ce_check req clang           "$CC"
_ce_check req opt             "$OPT"
_ce_check req llvm-link       "$LLVM_LINK"
_ce_check req cmake           "$CMAKE"
echo "  [ --  ] WORKSPACE_DIR  $WORKSPACE_DIR (created on first run)"

echo ""
echo "LLVM pass plugins (build with build/passes/build_passes_morello.sh):"
_ce_check opt SealInstr       "$REPO_DIR/analysis/llvm-passes/build_morello/libSealInstrumentationPass.so"
_ce_check opt CrossCompAnlz   "$REPO_DIR/analysis/llvm-passes/build_morello/libCrossCompartmentTypeAnalyzer.so"

echo ""
echo "Library sources (needed to build the library bitcode):"
_ce_check opt OPENSSL_SRC     "$OPENSSL_SRC"
_ce_check opt ZLIB_SRC        "$ZLIB_SRC"
_ce_check opt PCRE2_SRC       "$PCRE2_SRC"
_ce_check opt LIBEVENT_SRC    "$LIBEVENT_SRC"
_ce_check opt OSSL            "$OSSL"

echo ""
echo "Library bitcode outputs (produced by build/libraries/*, consumed by apps):"
_ce_check opt openssl.bc      "$WORKSPACE_DIR/libraries/openssl/openssl_merged.bc"
_ce_check opt zlib.bc         "$WORKSPACE_DIR/libraries/zlib/zlib_merged.bc"
_ce_check opt pcre2.bc        "$WORKSPACE_DIR/libraries/pcre2/pcre2_merged.bc"
_ce_check opt libevent.bc     "$WORKSPACE_DIR/libraries/libevent/libevent_merged.bc"

echo ""
echo "Application sources (only the ones you build need to exist):"
_ce_check opt NGINX_SRC       "$NGINX_SRC"
_ce_check opt REDIS_SRC       "$REDIS_SRC"
_ce_check opt WGET_SRC        "$WGET_SRC"
_ce_check opt CURL_SRC        "$CURL_SRC"
_ce_check opt MEMCACHED_SRC   "$MEMCACHED_SRC"
_ce_check opt LIGHTTPD_SRC    "$LIGHTTPD_SRC"

echo ""
echo "Benchmark runtimes and clients (macrobenchmarks/, microbenchmarks/ only):"
_ce_check opt BASELINE_LIBC   "$BASELINE_LIBC"
_ce_check opt MODIFIED_LIBC   "$MODIFIED_LIBC"
_ce_check opt AB              "$AB"
_ce_check opt redis-benchmark "$REDIS_BENCHMARK"


echo ""
echo "Functional-test tools:"
_ce_check opt FETCH           "$FETCH"
_ce_check opt NC              "$NC"
_ce_check opt REDIS_CLI       "$REDIS_CLI"
_ce_check opt OPENSSL_BIN     "$OPENSSL_BIN"
_ce_check opt NGINX_TESTS     "$NGINX_TESTS"

echo ""
echo "----------------------------------------------------------------------"
if [ "$_ce_reqmiss" -gt 0 ]; then
    echo "RESULT: $_ce_reqmiss REQUIRED path(s) MISSING — fix before running any script."
else
    echo "RESULT: all required paths present. ($_ce_optmiss optional path(s) not yet present.)"
fi
echo "======================================================================"

unset _ce_check
# Non-zero status if a required path is missing (harmless when sourced).
[ "$_ce_reqmiss" -eq 0 ]
