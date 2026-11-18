#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# test_redis.sh — Run Redis official Tcl test suite against our baseline and
#                 instrumented redis-server binaries.
#
# Testing principle: only ONE project binary is instrumented — redis-server.
# The redis Tcl harness spawns src/redis-server (which we swap for the variant
# under test) and talks to it with its own Tcl client; the stock src/redis-cli
# stays untouched. We never run an instrumented client.
#
# Both variants come from our pipeline so they differ ONLY by the seal pass:
#   baseline     = workspace/redis/baseline/redis-server      (pre-instrument bc)
#   instrumented = workspace/redis/instrumented/redis-server  (sealed)
# (Earlier this script compared against redis's own stock make build for the
#  baseline; that conflated the seal pass with unrelated build differences.)
#
# Usage:
#   ./test_redis.sh                    # run both baseline and instrumented
#   ./test_redis.sh --baseline-only
#   ./test_redis.sh --instrumented-only
#
# Prerequisites:
#   - tclsh (pkg64c install tcl86)
#   - Redis source at $REDIS_SRC (built with 'make' so runtest deps exist)
#   - baseline + instrumented redis-server in $WORKSPACE_DIR/redis/

set -e

REPO_DIR="${REPO_DIR:-$HOME/capward}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$REPO_DIR/workspace}"
REDIS_SRC="${REDIS_SRC:-$HOME/redis-${REDIS_VERSION:-7.0.12}}"

WKSP="$WORKSPACE_DIR/redis"
BASELINE_BINARY="$WKSP/baseline/redis-server"
BASELINE_LIBS="$WKSP/baseline"
INSTRUMENTED_BINARY="$WKSP/instrumented/redis-server"
INSTRUMENTED_LIBS="$WKSP/instrumented"

# Unit tests that pass on CheriBSD
TESTS="auth protocol keyspace expire quit bitops hyperloglog scan dump multi networking info introspection"

RUN_BASELINE=1
RUN_INSTRUMENTED=1

while [ "$#" -gt 0 ]; do
    case "$1" in
        --baseline-only)     RUN_INSTRUMENTED=0; shift;;
        --instrumented-only) RUN_BASELINE=0; shift;;
        *) echo "Unknown option: $1" >&2; exit 1;;
    esac
done

cd "$REDIS_SRC"

echo "======================================================================"
echo "Redis Functionality Tests (Tcl test suite)"
echo "======================================================================"
echo "Tests: $TESTS"
echo ""

# run_suite <label> <server-binary> <libdir>
# Swaps the variant server into src/redis-server (the path the Tcl harness
# spawns), runs the suite with LD_LIBRARY_PATH pointing at its sealed .so's,
# then restores the original src/redis-server. Only the SERVER is swapped;
# the client side is whatever the harness uses (stock).
run_suite() {
    label="$1"; binary="$2"; libs="$3"
    echo "--- $label ---"
    if [ ! -x "$binary" ]; then
        echo "  ERROR: missing server binary: $binary" >&2
        return 1
    fi

    cp src/redis-server src/redis-server.stock
    cp "$binary" src/redis-server
    # Restore the stock server even if a test aborts the shell.
    trap 'mv -f src/redis-server.stock src/redis-server 2>/dev/null || true' EXIT INT TERM

    pass=0; fail=0
    for test in $TESTS; do
        result=$(LD_LIBRARY_PATH="$libs" ./runtest --single unit/$test 2>&1 \
                 | grep -o "All tests passed" || true)
        if [ "$result" = "All tests passed" ]; then
            echo "  unit/$test: PASS"
            pass=$((pass + 1))
        else
            echo "  unit/$test: FAIL"
            fail=$((fail + 1))
        fi
    done

    mv -f src/redis-server.stock src/redis-server
    trap - EXIT INT TERM
    echo "  Result: $pass passed, $fail failed"
    echo ""
    return $fail
}

RC=0

if [ "$RUN_BASELINE" -eq 1 ]; then
    run_suite "Baseline" "$BASELINE_BINARY" "$BASELINE_LIBS" || RC=1
fi

if [ "$RUN_INSTRUMENTED" -eq 1 ]; then
    run_suite "Instrumented" "$INSTRUMENTED_BINARY" "$INSTRUMENTED_LIBS" || RC=1
fi

exit $RC
