#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# test_memcached.sh — PARITY test: instrumented memcached must match baseline
#                     per test, using memcached's Perl t/ suite.
#
# We do NOT use MemcachedTest's default launch path: it wraps memcached in
# $builddir/timedrun (a helper linked against the REAL libssl.so.3 /
# libevent-2.1.so.7, absent from our sealed LD_LIBRARY_PATH) and it always
# appends "-o relaxed_privileges" — a suboption our CheriBSD build doesn't
# register (HAVE_DROP_PRIVILEGES is undefined under cross-compile), so
# memcached exits "Illegal suboption". Both make every test fail to even start.
#
# Instead we use memcached's own supported external-server hook: launch the
# variant binary ourselves (correct LD_LIBRARY_PATH, no relaxed_privileges, no
# timedrun) and point the suite at it via T_MEMD_USE_DAEMON. A FRESH daemon is
# started per test so state doesn't leak. Only memcached is instrumented; the
# Perl harness is the client.
#
# Verdict: baseline-pass -> instrumented-fail is a REGRESSION (hard fail);
# baseline fail/skip on both is parity (ignored). PASS iff zero regressions.
#
# NOTE: some tests need a fresh/args-specific server that T_MEMD_USE_DAEMON
# can't provide (startup-arg tests, multi-server, restart) — those show as
# fail/fail = parity, not a regression.
#
# Usage:
#   ./test_memcached.sh                      # parity: run both, compare
#   ./test_memcached.sh --baseline-only
#   ./test_memcached.sh --instrumented-only

set -e

REPO_DIR="${REPO_DIR:-$HOME/capward}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$REPO_DIR/workspace}"
MEMCACHED_SRC="${MEMCACHED_SRC:-$HOME/memcached-${MEMCACHED_VERSION:-1.6.21}}"
PORT="${MEMCACHED_TEST_PORT:-7799}"
NC="${NC:-/usr/bin/nc}"

WKSP="$WORKSPACE_DIR/memcached"
BASELINE_BINARY="$WKSP/baseline/memcached";         BASELINE_LIBS="$WKSP/baseline"
INSTRUMENTED_BINARY="$WKSP/instrumented/memcached"; INSTRUMENTED_LIBS="$WKSP/instrumented"

# Tests that run against a single plain daemon. Parity ignores baseline
# failures, so a modest set is safe; startup-arg / multi-server tests are
# omitted (T_MEMD_USE_DAEMON can't satisfy them).
TESTS="t/getset.t t/incrdecr.t t/delete.t t/flush-all.t t/noreply.t"

RUN_BASELINE=1; RUN_INSTRUMENTED=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --baseline-only)     RUN_INSTRUMENTED=0; shift;;
        --instrumented-only) RUN_BASELINE=0; shift;;
        *) echo "Unknown option: $1" >&2; exit 1;;
    esac
done

[ -d "$MEMCACHED_SRC" ] || { echo "ERROR: memcached source not found at $MEMCACHED_SRC" >&2; exit 1; }
[ -x "$NC" ] || { echo "ERROR: nc not found at $NC (override NC=...)" >&2; exit 1; }
cd "$MEMCACHED_SRC"

DAEMON_PID=""
stop_daemon() {
    [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null || true
    [ -n "$DAEMON_PID" ] && wait "$DAEMON_PID" 2>/dev/null || true
    DAEMON_PID=""
}
trap 'stop_daemon' EXIT INT TERM

# classify <binary> <libdir> <test> -> pass|skip|fail|missing
# Launches a fresh variant daemon (no relaxed_privileges / timedrun), points
# the suite at it via T_MEMD_USE_DAEMON, classifies by prove exit status.
classify() {
    _bin="$1"; _libs="$2"; _t="$3"
    if [ ! -f "$_bin" ]; then echo missing; return; fi

    LD_LIBRARY_PATH="$_libs" "$_bin" -p "$PORT" -U 0 -m 128 -l 127.0.0.1 \
        >/dev/null 2>&1 &
    DAEMON_PID=$!

    _ready=0; _i=0
    while [ "$_i" -lt 40 ]; do
        if printf 'version\r\nquit\r\n' | "$NC" -w 1 127.0.0.1 "$PORT" 2>/dev/null \
             | grep -q '^VERSION'; then _ready=1; break; fi
        if ! kill -0 "$DAEMON_PID" 2>/dev/null; then break; fi
        sleep 0.2; _i=$((_i + 1))
    done
    if [ "$_ready" -ne 1 ]; then stop_daemon; echo fail; return; fi

    _out=$(T_MEMD_USE_DAEMON="127.0.0.1:$PORT" prove "$_t" 2>&1) && _rc=0 || _rc=$?
    stop_daemon

    if printf '%s' "$_out" | grep -q 'skipped:'; then
        echo skip
    elif [ "$_rc" -eq 0 ]; then
        echo pass
    else
        echo fail
    fi
}

echo "======================================================================"
echo "memcached parity test (instrumented vs baseline, per test)"
echo "  server launched by us + T_MEMD_USE_DAEMON (no timedrun/relaxed_privileges)"
echo "======================================================================"

# Single-variant listing
if [ "$RUN_BASELINE" -eq 0 ] || [ "$RUN_INSTRUMENTED" -eq 0 ]; then
    if [ "$RUN_BASELINE" -eq 1 ]; then lbl=baseline; bin="$BASELINE_BINARY"; libs="$BASELINE_LIBS"; fi
    if [ "$RUN_INSTRUMENTED" -eq 1 ]; then lbl=instrumented; bin="$INSTRUMENTED_BINARY"; libs="$INSTRUMENTED_LIBS"; fi
    echo "Variant: $lbl ($bin)"; echo ""
    for t in $TESTS; do printf "  %-16s %s\n" "$t" "$(classify "$bin" "$libs" "$t")"; done
    exit 0
fi

printf "  %-16s %-9s %-12s %s\n" "TEST" "BASELINE" "INSTRUMENTED" "VERDICT"
printf "  %-16s %-9s %-12s %s\n" "----" "--------" "------------" "-------"
REGRESSIONS=0; DIFFERS=0
for t in $TESTS; do
    b=$(classify "$BASELINE_BINARY" "$BASELINE_LIBS" "$t")
    i=$(classify "$INSTRUMENTED_BINARY" "$INSTRUMENTED_LIBS" "$t")
    if [ "$b" = "$i" ]; then
        verdict="parity"
    elif [ "$b" = "pass" ] && [ "$i" = "fail" ]; then
        verdict="** REGRESSION **"; REGRESSIONS=$((REGRESSIONS + 1))
    else
        verdict="differs"; DIFFERS=$((DIFFERS + 1))
    fi
    printf "  %-16s %-9s %-12s %s\n" "$t" "$b" "$i" "$verdict"
done

echo ""
echo "======================================================================"
echo "  Regressions (baseline pass -> instrumented fail): $REGRESSIONS"
echo "  Other differences:                                $DIFFERS"
if [ "$REGRESSIONS" -eq 0 ]; then
    echo "  Result: PASS (instrumentation preserves baseline behaviour)"
else
    echo "  Result: FAIL (instrumentation regressed $REGRESSIONS test(s))"
fi
echo "======================================================================"
[ "$REGRESSIONS" -eq 0 ]
