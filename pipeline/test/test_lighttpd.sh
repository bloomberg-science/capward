#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# test_lighttpd.sh — PARITY test: the instrumented lighttpd must match the
#                    baseline lighttpd per scenario, outcome for outcome.
#
# Methodology (same as test_nginx.sh): we do NOT assert absolute success — a
# scenario may fail for environment reasons unrelated to sealing. We assert that
# our seal instrumentation does not CHANGE any scenario's outcome vs baseline:
#   baseline pass + instrumented pass -> parity     (ok)
#   baseline fail + instrumented fail -> parity     (ok — env / negative case)
#   baseline pass + instrumented fail -> REGRESSION (our fault; hard fail)
#   any other mismatch                -> differs    (flagged, investigate)
# Overall PASS iff zero regressions.
#
# Only lighttpd (the server) is instrumented; clients are stock base-system
# tools (fetch, openssl s_client, nc) linking base libssl. This is a
# self-contained request battery (start the variant server, drive scenarios),
# not lighttpd's upstream Perl suite — analogous to the wget/curl parity tests.
# Use smoke_lighttpd.sh first for a fast liveness check.
#
# Scenarios exercise: core (HTTP), lighttpd<->openssl (HTTPS, HTTPS keepalive =
# repeated SSL boundary crossings), lighttpd<->zlib (gzip), HEAD, and a 404
# error path.
#
# Usage:
#   ./test_lighttpd.sh                      # parity: run both, compare
#   ./test_lighttpd.sh --baseline-only
#   ./test_lighttpd.sh --instrumented-only

set -e

REPO_DIR="${REPO_DIR:-$HOME/capward}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$REPO_DIR/workspace}"
WKSP="$WORKSPACE_DIR/lighttpd"
PORT="${LIGHTTPD_TEST_PORT:-7741}"     # HTTP
SSL_PORT=$((PORT + 1))                  # HTTPS

FETCH="${FETCH:-/usr/bin/fetch}"
OPENSSL_BIN="${OPENSSL_BIN:-/usr/bin/openssl}"
NC="${NC:-/usr/bin/nc}"
EXPECT="smoke-ok"

# This test talks only to a server on localhost. If http_proxy/https_proxy is
# set in the environment (e.g. by the wget/curl internet tests), FreeBSD fetch
# would route localhost through any configured HTTP proxy and fail. Bypass localhost
# rather than unsetting the proxy entirely.
export no_proxy="127.0.0.1,localhost,::1${no_proxy:+,${no_proxy}}"
export NO_PROXY="$no_proxy"

SCENARIOS="http https gzip keepalive head notfound"

RUN_BASELINE=1
RUN_INSTRUMENTED=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --baseline-only)     RUN_INSTRUMENTED=0; shift;;
        --instrumented-only) RUN_BASELINE=0; shift;;
        *) echo "Unknown option: $1" >&2; exit 1;;
    esac
done

SERVER_PID=""
RUNDIR=""
stop_server() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    [ -n "$SERVER_PID" ] && wait "$SERVER_PID" 2>/dev/null || true
    [ -n "$RUNDIR" ] && rm -rf "$RUNDIR"
    SERVER_PID=""; RUNDIR=""
}

# start_server <variant> -> 0 if serving, 1 otherwise. Sets SERVER_PID/RUNDIR.
start_server() {
    variant="$1"
    server="$WKSP/$variant/lighttpd"
    libs="$WKSP/$variant"
    [ -x "$server" ] || return 1

    RUNDIR=$(mktemp -d "/tmp/lighttpd_test_${variant}.XXXXXX")
    mkdir -p "$RUNDIR/www"
    printf '%s\n' "$EXPECT" > "$RUNDIR/www/index.html"

    "$OPENSSL_BIN" req -x509 -newkey rsa:2048 -nodes \
        -keyout "$RUNDIR/key.pem" -out "$RUNDIR/cert.pem" \
        -days 1 -subj '/CN=localhost' >/dev/null 2>&1 || return 1

    cat > "$RUNDIR/lighttpd.conf" <<EOF
server.document-root = "$RUNDIR/www"
server.bind          = "127.0.0.1"
server.port          = $PORT
server.modules       = ( "mod_openssl", "mod_deflate" )
server.errorlog      = "$RUNDIR/error.log"
mimetype.assign      = ( ".html" => "text/html" )
index-file.names     = ( "index.html" )

\$SERVER["socket"] == "127.0.0.1:$SSL_PORT" {
    ssl.engine  = "enable"
    ssl.pemfile = "$RUNDIR/cert.pem"
    ssl.privkey = "$RUNDIR/key.pem"
}

deflate.mimetypes         = ( "text/html", "text/plain" )
deflate.allowed-encodings = ( "gzip" )
# Force compression of our tiny ($EXPECT) body: lighttpd's default
# deflate.min-compress-size would skip a 9-byte response, so no
# Content-Encoding: gzip header, and the zlib-boundary check would fail.
deflate.min-compress-size = 1
EOF

    LD_LIBRARY_PATH="$libs" "$server" -D -f "$RUNDIR/lighttpd.conf" &
    SERVER_PID=$!

    i=0
    while [ "$i" -lt 50 ]; do
        if "$FETCH" -qo /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then return 0; fi
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then return 1; fi
        sleep 0.2
        i=$((i + 1))
    done
    return 1
}

# scenario <id> -> prints pass|fail (server assumed running)
scenario() {
    case "$1" in
        http)
            b=$("$FETCH" -qo - "http://127.0.0.1:$PORT/" 2>/dev/null) || b=""
            [ "$b" = "$EXPECT" ] && echo pass || echo fail;;
        https)
            b=$("$FETCH" --no-verify-peer --no-verify-hostname -qo - \
                "https://127.0.0.1:$SSL_PORT/" 2>/dev/null) || b=""
            [ "$b" = "$EXPECT" ] && echo pass || echo fail;;
        gzip)
            printf 'GET / HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n' \
                | "$OPENSSL_BIN" s_client -quiet -connect "127.0.0.1:$SSL_PORT" 2>/dev/null \
                | grep -qai 'Content-Encoding: *gzip' && echo pass || echo fail;;
        keepalive)
            # two requests on one TLS connection -> repeated SSL seal crossings
            n=$(printf 'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\nGET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' \
                | "$OPENSSL_BIN" s_client -quiet -connect "127.0.0.1:$SSL_PORT" 2>/dev/null \
                | grep -c "$EXPECT")
            [ "${n:-0}" -ge 2 ] && echo pass || echo fail;;
        head)
            printf 'HEAD / HTTP/1.0\r\n\r\n' | "$NC" -w 4 127.0.0.1 "$PORT" 2>/dev/null \
                | grep -qi '200' && echo pass || echo fail;;
        notfound)
            # 404 -> fetch exits non-zero on both variants -> parity
            b=$("$FETCH" -qo - "http://127.0.0.1:$PORT/nonexistent-seal-test-xyz" 2>/dev/null) || b=""
            [ "$b" = "$EXPECT" ] && echo pass || echo fail;;
        *) echo fail;;
    esac
}

# run_variant <variant> <resultfile> -> writes "id result" lines
run_variant() {
    variant="$1"; out="$2"
    : > "$out"
    if ! start_server "$variant"; then
        echo "    (warning) $variant lighttpd did not start; scenarios recorded as fail" >&2
        [ -n "$RUNDIR" ] && tail -10 "$RUNDIR/error.log" 2>/dev/null | sed 's/^/      | /' >&2 || true
        for s in $SCENARIOS; do echo "$s fail" >> "$out"; done
        stop_server
        return
    fi
    for s in $SCENARIOS; do
        r=$(scenario "$s")
        echo "$s $r" >> "$out"
    done
    stop_server
}

get_result() { awk -v k="$1" '$1==k{print $2}' "$2"; }

echo "======================================================================"
echo "lighttpd parity test (instrumented vs baseline, per scenario)"
echo "  HTTP :$PORT   HTTPS :$SSL_PORT"
echo "======================================================================"

for t in "$FETCH" "$OPENSSL_BIN" "$NC"; do
    if [ ! -x "$t" ]; then echo "ERROR: missing client tool: $t" >&2; exit 1; fi
done

# ---- Single-variant listing ----
if [ "$RUN_BASELINE" -eq 0 ] || [ "$RUN_INSTRUMENTED" -eq 0 ]; then
    if [ "$RUN_BASELINE" -eq 1 ]; then label="baseline"; fi
    if [ "$RUN_INSTRUMENTED" -eq 1 ]; then label="instrumented"; fi
    RES=$(mktemp /tmp/lighttpd_res.XXXXXX)
    run_variant "$label" "$RES"
    echo "Variant: $label"
    echo ""
    for s in $SCENARIOS; do printf "  %-12s %s\n" "$s" "$(get_result "$s" "$RES")"; done
    rm -f "$RES"
    exit 0
fi

# ---- Parity mode ----
RES_B=$(mktemp /tmp/lighttpd_res_b.XXXXXX)
RES_I=$(mktemp /tmp/lighttpd_res_i.XXXXXX)
run_variant baseline     "$RES_B"
run_variant instrumented "$RES_I"

printf "  %-12s %-9s %-12s %s\n" "SCENARIO" "BASELINE" "INSTRUMENTED" "VERDICT"
printf "  %-12s %-9s %-12s %s\n" "--------" "--------" "------------" "-------"

REGRESSIONS=0
DIFFERS=0
for s in $SCENARIOS; do
    b=$(get_result "$s" "$RES_B")
    i=$(get_result "$s" "$RES_I")
    if [ "$b" = "$i" ]; then
        verdict="parity"
    elif [ "$b" = "pass" ] && [ "$i" = "fail" ]; then
        verdict="** REGRESSION **"; REGRESSIONS=$((REGRESSIONS + 1))
    else
        verdict="differs"; DIFFERS=$((DIFFERS + 1))
    fi
    printf "  %-12s %-9s %-12s %s\n" "$s" "$b" "$i" "$verdict"
done
rm -f "$RES_B" "$RES_I"

echo ""
echo "======================================================================"
echo "  Regressions (baseline pass -> instrumented fail): $REGRESSIONS"
echo "  Other differences:                                $DIFFERS"
if [ "$REGRESSIONS" -eq 0 ]; then
    echo "  Result: PASS (instrumentation preserves baseline behaviour)"
else
    echo "  Result: FAIL (instrumentation regressed $REGRESSIONS scenario(s))"
fi
echo "======================================================================"

[ "$REGRESSIONS" -eq 0 ]
