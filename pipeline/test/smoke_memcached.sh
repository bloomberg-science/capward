#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# smoke_memcached.sh — liveness + seal-boundary smoke test for sealed memcached.
#
# Only memcached is instrumented; the client is the base-system `nc` (memcached
# text protocol over TCP) — base-linked, so no /usr/local lib dependency.
#
# Plain set/get/incr/delete already crosses memcached's MAIN seal boundary:
# libevent is its own compartment and drives every accept/read event, calling
# back into memcached across the boundary — so a served request exercises the
# memcached<->libevent sealing. (openssl/TLS is a secondary boundary reached
# only with -Z + certs; not covered here.) A catastrophic sealing bug stops
# memcached from serving and this test catches it.
#
# Runs both variants (absolute liveness, no diff). For parity vs baseline use
# test_memcached.sh.
#
# Usage: ./smoke_memcached.sh [--instrumented-only|--baseline-only]

set -e

REPO_DIR="${REPO_DIR:-$HOME/capward}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$REPO_DIR/workspace}"
PORT="${MEMCACHED_SMOKE_PORT:-7732}"
WKSP="$WORKSPACE_DIR/memcached"
NC="${NC:-/usr/bin/nc}"

RUN_INSTRUMENTED=1; RUN_BASELINE=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --instrumented-only) RUN_BASELINE=0; shift;;
        --baseline-only)     RUN_INSTRUMENTED=0; shift;;
        *) echo "Unknown option: $1" >&2; exit 1;;
    esac
done

echo "======================================================================"
echo "memcached smoke test (server = variant; client = stock nc)"
echo "======================================================================"
if [ ! -x "$NC" ]; then
    echo "ERROR: nc not found/executable at $NC (override with NC=...)" >&2
    exit 1
fi
echo "Client (stock): $NC"
echo ""

SERVER_PID=""
LOGF=""
stop_server() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    [ -n "$SERVER_PID" ] && wait "$SERVER_PID" 2>/dev/null || true
    [ -n "$LOGF" ] && rm -f "$LOGF"
    SERVER_PID=""; LOGF=""
}

# mc <commands-with-\r\n-escapes> -> prints server response
mc() { printf '%b' "$1" | "$NC" -w 2 127.0.0.1 "$PORT" 2>/dev/null; }

smoke_one() {
    variant="$1"
    server="$WKSP/$variant/memcached"
    libs="$WKSP/$variant"

    echo "--- $variant ---"
    if [ ! -x "$server" ]; then
        echo "    FAIL server binary missing: $server" >&2
        return 1
    fi

    LOGF=$(mktemp "/tmp/memcached_smoke_${variant}.XXXXXX")
    # Foreground (no -d), background it; -U 0 disables UDP; bind loopback.
    LD_LIBRARY_PATH="$libs" "$server" -p "$PORT" -U 0 -m 64 -l 127.0.0.1 \
        >"$LOGF" 2>&1 &
    SERVER_PID=$!

    ready=0; i=0
    while [ "$i" -lt 50 ]; do
        if mc 'version\r\nquit\r\n' | grep -q '^VERSION'; then ready=1; break; fi
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then break; fi
        sleep 0.2; i=$((i + 1))
    done
    if [ "$ready" -ne 1 ]; then
        echo "    FAIL memcached did not become ready — server output:" >&2
        tail -20 "$LOGF" 2>/dev/null | sed 's/^/      | /' >&2 || true
        stop_server
        return 1
    fi

    rc=0
    if mc 'set smoke:k 0 0 5\r\nhello\r\nquit\r\n' | grep -q 'STORED'; then
        echo "    ok   SET"
    else echo "    FAIL SET" >&2; rc=1; fi

    out=$(mc 'get smoke:k\r\nquit\r\n')
    if printf '%s' "$out" | grep -q '^hello'; then
        echo "    ok   GET (hello)"
    else echo "    FAIL GET: got '$out'" >&2; rc=1; fi

    mc 'set smoke:n 0 0 1\r\n5\r\nquit\r\n' >/dev/null 2>&1 || true
    incr=$(mc 'incr smoke:n 3\r\nquit\r\n' | tr -d '\r\n')
    if [ "$incr" = "8" ]; then
        echo "    ok   INCR (5+3=8)"
    else echo "    FAIL INCR: got '$incr'" >&2; rc=1; fi

    if mc 'delete smoke:k\r\nquit\r\n' | grep -q 'DELETED'; then
        echo "    ok   DELETE"
    else echo "    FAIL DELETE" >&2; rc=1; fi

    stop_server
    if [ "$rc" -eq 0 ]; then echo "    PASS $variant"; else echo "    FAIL $variant" >&2; fi
    return $rc
}

OVERALL=0
if [ "$RUN_INSTRUMENTED" -eq 1 ]; then smoke_one instrumented || OVERALL=1; echo ""; fi
if [ "$RUN_BASELINE" -eq 1 ]; then smoke_one baseline || OVERALL=1; echo ""; fi

echo "======================================================================"
if [ "$OVERALL" -eq 0 ]; then echo "Smoke test: PASS"; else echo "Smoke test: FAIL"; fi
echo "======================================================================"
exit $OVERALL
