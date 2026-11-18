#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# smoke_nginx.sh — liveness + seal-boundary smoke test for the sealed nginx.
#
# Testing principle: only ONE project binary is instrumented — nginx. Clients
# are stock base-system tools (fetch, openssl s_client), which link the BASE
# libssl/libcrypto (/usr/lib), not /usr/local — so no instrumented client and no
# TLS-lib path headache.
#
# Unlike a plain-HTTP check (which only proves nginx boots and its four
# __seal_init constructors ran), this drives requests that actually CROSS the
# seal boundaries at runtime:
#   1. HTTP  GET            — basic serve (nginx compartment)
#   2. HTTPS GET            — TLS handshake seals/unseals SSL*/SSL_CTX* across
#                             nginx<->openssl many times (the boundary where the
#                             paper's sealing crashes surfaced)
#   3. HTTPS + gzip         — response compression exercises nginx<->zlib
# A self-signed cert is generated per run with the base openssl.
#
# Runs for both variants; a catastrophic sealing bug (tagless __sealcap, bad
# otype, unsealed pointer where sealed is expected) shows up as a failed
# handshake / crashed worker / missing response.
#
# Usage:
#   ./smoke_nginx.sh                     # both variants (instrumented + baseline)
#   ./smoke_nginx.sh --instrumented-only
#   ./smoke_nginx.sh --baseline-only

set -e

REPO_DIR="${REPO_DIR:-$HOME/capward}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$REPO_DIR/workspace}"
PORT="${NGINX_SMOKE_PORT:-7721}"      # HTTP
SSL_PORT=$((PORT + 1))                 # HTTPS
WKSP="$WORKSPACE_DIR/nginx"

# Stock base-system clients (base libssl, no /usr/local dependency).
FETCH="${FETCH:-/usr/bin/fetch}"
OPENSSL_BIN="${OPENSSL_BIN:-/usr/bin/openssl}"

# This test talks only to a server on localhost. If http_proxy/https_proxy is
# set in the environment (e.g. by the wget/curl internet tests), FreeBSD fetch
# would route localhost through any configured HTTP proxy and fail. Bypass localhost
# rather than unsetting the proxy entirely.
export no_proxy="127.0.0.1,localhost,::1${no_proxy:+,${no_proxy}}"
export NO_PROXY="$no_proxy"

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
echo "nginx smoke test (server = variant; clients = stock fetch/openssl)"
echo "  HTTP :$PORT   HTTPS :$SSL_PORT"
echo "======================================================================"

for t in "$FETCH" "$OPENSSL_BIN"; do
    if [ ! -x "$t" ]; then
        echo "ERROR: required client tool not found/executable: $t" >&2
        exit 1
    fi
done
echo "Clients (stock): $FETCH, $OPENSSL_BIN"
echo ""

EXPECT="smoke-ok"

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
    server="$WKSP/$variant/nginx"
    libs="$WKSP/$variant"

    echo "--- $variant ---"
    if [ ! -x "$server" ]; then
        echo "    FAIL server binary missing: $server" >&2
        return 1
    fi

    RUNDIR=$(mktemp -d "/tmp/nginx_smoke_${variant}.XXXXXX")
    mkdir -p "$RUNDIR/logs" "$RUNDIR/tmp" "$RUNDIR/www"
    printf '%s\n' "$EXPECT" > "$RUNDIR/www/index.html"

    # Self-signed cert for the HTTPS listener (generated with the base openssl).
    if ! "$OPENSSL_BIN" req -x509 -newkey rsa:2048 -nodes \
            -keyout "$RUNDIR/key.pem" -out "$RUNDIR/cert.pem" \
            -days 1 -subj '/CN=localhost' >/dev/null 2>&1; then
        echo "    FAIL could not generate self-signed cert" >&2
        stop_server
        return 1
    fi

    cat > "$RUNDIR/nginx.conf" <<EOF
daemon off;
worker_processes 1;
error_log $RUNDIR/logs/error.log info;
pid $RUNDIR/logs/nginx.pid;
events { worker_connections 64; }
http {
    access_log $RUNDIR/logs/access.log;
    client_body_temp_path $RUNDIR/tmp/client_body;
    proxy_temp_path       $RUNDIR/tmp/proxy;
    fastcgi_temp_path     $RUNDIR/tmp/fastcgi;
    uwsgi_temp_path       $RUNDIR/tmp/uwsgi;
    scgi_temp_path        $RUNDIR/tmp/scgi;
    types_hash_bucket_size 128;
    variables_hash_bucket_size 128;
    default_type text/plain;
    gzip on;
    gzip_min_length 1;
    gzip_types text/plain;
    server {
        listen 127.0.0.1:$PORT;
        listen 127.0.0.1:$SSL_PORT ssl;
        server_name localhost;
        ssl_certificate     $RUNDIR/cert.pem;
        ssl_certificate_key $RUNDIR/key.pem;
        root $RUNDIR/www;
        location / { index index.html; }
    }
}
EOF

    # Only the SERVER is the variant binary; clients are always stock.
    LD_LIBRARY_PATH="$libs" "$server" -p "$RUNDIR" -c "$RUNDIR/nginx.conf" &
    SERVER_PID=$!

    # Wait for readiness (a successful plain-HTTP GET), up to ~10s.
    ready=0; i=0
    while [ "$i" -lt 50 ]; do
        if "$FETCH" -qo /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then ready=1; break; fi
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then break; fi
        sleep 0.2
        i=$((i + 1))
    done

    if [ "$ready" -ne 1 ]; then
        echo "    FAIL nginx did not serve a request — last lines of its error log:" >&2
        tail -20 "$RUNDIR/logs/error.log" 2>/dev/null | sed 's/^/      | /' >&2 || true
        stop_server
        return 1
    fi

    rc=0

    # 1. HTTP GET (nginx serves at all)
    body=$("$FETCH" -qo - "http://127.0.0.1:$PORT/" 2>/dev/null) || body=""
    if [ "$body" = "$EXPECT" ]; then
        echo "    ok   HTTP  GET / ('$body')"
    else
        echo "    FAIL HTTP  GET /: expected '$EXPECT', got '$body'" >&2; rc=1
    fi

    # 2. HTTPS GET — exercises nginx<->openssl SSL*/SSL_CTX* sealing
    sbody=$("$FETCH" --no-verify-peer --no-verify-hostname -qo - \
            "https://127.0.0.1:$SSL_PORT/" 2>/dev/null) || sbody=""
    if [ "$sbody" = "$EXPECT" ]; then
        echo "    ok   HTTPS GET / ('$sbody')  [openssl seal boundary]"
    else
        echo "    FAIL HTTPS GET /: expected '$EXPECT', got '$sbody'" >&2; rc=1
    fi

    # 3. HTTPS + gzip — exercises nginx<->zlib (response compression).
    #    fetch can't request gzip, so use base openssl s_client for a raw
    #    Accept-Encoding: gzip request and check for the Content-Encoding header.
    printf 'GET / HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n' \
        | "$OPENSSL_BIN" s_client -quiet -connect "127.0.0.1:$SSL_PORT" 2>/dev/null \
        > "$RUNDIR/gzip.out" || true
    if grep -qai 'Content-Encoding: *gzip' "$RUNDIR/gzip.out"; then
        echo "    ok   HTTPS gzip response          [zlib seal boundary]"
    else
        echo "    FAIL HTTPS gzip: no 'Content-Encoding: gzip' in response" >&2; rc=1
    fi

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
