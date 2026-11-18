#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# smoke_redis.sh — fast liveness smoke test for the sealed redis-server.
#
# Testing principle: only ONE project binary is instrumented — redis-server.
# The client (redis-cli) is ALWAYS the stock, NON-instrumented build from the
# redis source tree. We never run an instrumented client. (redis-cli is a
# separate compartment-less binary; e.g. cliSSLconfig must not leak into the
# redis-server compartment.)
#
# For each variant it starts that redis-server (with LD_LIBRARY_PATH pointing at
# the variant's sealed .so's), waits for readiness, then runs a handful of
# PING/SET/GET/list/hash/DEL checks via the stock redis-cli, and shuts it down.
# Exits non-zero if any variant fails a check or fails to start — so it catches
# the catastrophic sealing bugs (tagless __sealcap, bad .init_array otype, etc.)
# that prevent the server from even coming up.
#
# This is a smoke test, not a functional suite — for the full Tcl unit tests
# (including TLS, which actually exercises the redis<->openssl seal boundary)
# use test_redis.sh.
#
# Usage:
#   ./smoke_redis.sh                     # both variants (instrumented + baseline)
#   ./smoke_redis.sh --instrumented-only
#   ./smoke_redis.sh --baseline-only

set -e

REPO_DIR="${REPO_DIR:-$HOME/capward}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$REPO_DIR/workspace}"
REDIS_SRC="${REDIS_SRC:-$HOME/redis-${REDIS_VERSION:-7.0.12}}"
OPENSSL_SRC="${OPENSSL_SRC:-$HOME/lib_srcs/openssl}"
OPENSSL_BUILD="${OPENSSL_BUILD:-$OPENSSL_SRC/build_purecap}"

# Stock, NON-instrumented client from the redis 'make' build.
REDIS_CLI="${REDIS_CLI:-$REDIS_SRC/src/redis-cli}"

# The stock redis-cli is TLS-enabled, so it links the REAL (non-sealed)
# libssl.so.3 / libcrypto.so.3 — a DIFFERENT path than the server's sealed
# libssl_sealed.so. The client must never load the sealed libs.
CLIENT_LIBS="${REDIS_CLI_LIBS:-$OPENSSL_BUILD}"

PORT="${REDIS_SMOKE_PORT:-7711}"
WKSP="$WORKSPACE_DIR/redis"

RUN_INSTRUMENTED=1
RUN_BASELINE=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --instrumented-only) RUN_BASELINE=0; shift;;
        --baseline-only)     RUN_INSTRUMENTED=0; shift;;
        *) echo "Unknown option: $1" >&2; exit 1;;
    esac
done

echo "======================================================================"
echo "Redis smoke test (server = variant binary, client = stock redis-cli)"
echo "======================================================================"

if [ ! -x "$REDIS_CLI" ]; then
    echo "ERROR: stock redis-cli not found/executable: $REDIS_CLI" >&2
    echo "  Build it with the redis 'make' in $REDIS_SRC — it must be the" >&2
    echo "  non-instrumented client. Override with REDIS_CLI=/path/to/redis-cli." >&2
    exit 1
fi

# Preflight: make sure the client can actually load its libs and run. This
# needs no server (--version exits 0 standalone), so it turns a missing
# libssl.so.3 into a crisp error instead of a 10s readiness timeout.
if ! LD_LIBRARY_PATH="$CLIENT_LIBS" "$REDIS_CLI" --version >/dev/null 2>&1; then
    echo "ERROR: redis-cli cannot run — most likely it can't find the real" >&2
    echo "  (non-sealed) libssl.so.3 / libcrypto.so.3." >&2
    echo "  Client lib path tried: $CLIENT_LIBS" >&2
    echo "  Set REDIS_CLI_LIBS to the dir holding the real libssl.so.3." >&2
    exit 1
fi

echo "Client (stock): $REDIS_CLI"
echo "Client libs:    $CLIENT_LIBS  (real, non-sealed openssl)"
echo ""

cli() { LD_LIBRARY_PATH="$CLIENT_LIBS" "$REDIS_CLI" -p "$PORT" "$@"; }

# assert_eq <expected> <actual> <label>  → 0 on match, 1 on mismatch
assert_eq() {
    if [ "$2" = "$1" ]; then
        echo "    ok   $3 ('$2')"
        return 0
    fi
    echo "    FAIL $3: expected '$1', got '$2'" >&2
    return 1
}

SERVER_PID=""
RUNDIR=""
stop_server() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    [ -n "$SERVER_PID" ] && wait "$SERVER_PID" 2>/dev/null || true
    [ -n "$RUNDIR" ] && rm -rf "$RUNDIR"
    SERVER_PID=""; RUNDIR=""
}

# smoke_one <variant>  (variant = instrumented | baseline)
smoke_one() {
    variant="$1"
    server="$WKSP/$variant/redis-server"
    libs="$WKSP/$variant"

    echo "--- $variant ---"
    if [ ! -x "$server" ]; then
        echo "    FAIL server binary missing: $server" >&2
        return 1
    fi

    # Isolated runtime dir so variants never share state.
    RUNDIR=$(mktemp -d "/tmp/redis_smoke_${variant}.XXXXXX")

    # Only the SERVER is the variant binary; the client is always stock.
    LD_LIBRARY_PATH="$libs" "$server" \
        --port "$PORT" \
        --bind 127.0.0.1 \
        --dir "$RUNDIR" \
        --save "" \
        --appendonly no \
        --daemonize no \
        --logfile "$RUNDIR/redis.log" &
    SERVER_PID=$!

    # Wait for readiness (PING -> PONG), up to ~10s.
    ready=0; i=0
    while [ "$i" -lt 50 ]; do
        if [ "$(cli ping 2>/dev/null)" = "PONG" ]; then ready=1; break; fi
        # Bail early if the server process already died.
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then break; fi
        sleep 0.2
        i=$((i + 1))
    done

    if [ "$ready" -ne 1 ]; then
        echo "    FAIL server did not become ready — last lines of its log:" >&2
        tail -20 "$RUNDIR/redis.log" 2>/dev/null | sed 's/^/      | /' >&2 || true
        stop_server
        return 1
    fi

    rc=0
    assert_eq "PONG"  "$(cli ping)"              "PING"   || rc=1
    assert_eq "OK"    "$(cli set smoke:k hello)" "SET"    || rc=1
    assert_eq "hello" "$(cli get smoke:k)"       "GET"    || rc=1
    assert_eq "10"    "$(cli append smoke:k world)" "APPEND" || rc=1  # 'hello'+'world' = len 10
    assert_eq "2"     "$(cli rpush smoke:l a b)"  "RPUSH"  || rc=1
    assert_eq "a"     "$(cli lindex smoke:l 0)"   "LINDEX" || rc=1
    assert_eq "1"     "$(cli hset smoke:h f v)"   "HSET"   || rc=1
    assert_eq "v"     "$(cli hget smoke:h f)"     "HGET"   || rc=1
    assert_eq "1"     "$(cli del smoke:k)"        "DEL"    || rc=1

    stop_server
    if [ "$rc" -eq 0 ]; then
        echo "    PASS $variant"
    else
        echo "    FAIL $variant" >&2
    fi
    return $rc
}

OVERALL=0
if [ "$RUN_INSTRUMENTED" -eq 1 ]; then
    smoke_one instrumented || OVERALL=1
    echo ""
fi
if [ "$RUN_BASELINE" -eq 1 ]; then
    smoke_one baseline || OVERALL=1
    echo ""
fi

echo "======================================================================"
if [ "$OVERALL" -eq 0 ]; then
    echo "Smoke test: PASS"
else
    echo "Smoke test: FAIL"
fi
echo "======================================================================"
exit $OVERALL
