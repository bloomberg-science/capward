#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# smoke_wget.sh — liveness + seal-boundary smoke test for the sealed wget.
#
# Testing principle: wget is the ONLY instrumented binary and it is a CLIENT,
# so (unlike the nginx smoke, where the variant is the server) we point the
# variant wget at a local test server: the baseline lighttpd, with HTTPS and
# gzip, started by local_https_server.sh.
#
# The three fetches each cross a different runtime seal boundary:
#   1. HTTP  GET            — basic retrieval (wget compartment only)
#   2. HTTPS GET            — end-to-end TLS handshake seals/unseals SSL*/SSL_CTX*
#                             across wget<->openssl many times.
#   3. HTTPS + gzip         — --compression=gzip decompresses a gzip response,
#                             exercising wget<->zlib.
# --no-check-certificate keeps the test about SEALING, not PKI/CA config.
#
# A catastrophic sealing bug (tagless __sealcap, bad otype, unsealed pointer
# where sealed is expected) shows up as a crashed fetch / empty body.
#
# Usage:
#   ./smoke_wget.sh                     # both variants (instrumented + baseline)
#   ./smoke_wget.sh --instrumented-only
#   ./smoke_wget.sh --baseline-only
#   HTTP_PROXY_URL=http://host:port ./smoke_wget.sh
#   ./smoke_wget.sh --no-proxy          # direct connectivity (no proxy)

set -e

REPO_DIR="${REPO_DIR:-$HOME/capward}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$REPO_DIR/workspace}"
WKSP="$WORKSPACE_DIR/wget"
# Empty = direct connection. Set HTTP_PROXY_URL if your network needs a proxy.
PROXY="${HTTP_PROXY_URL:-}"

# Endpoints: the local test server. Each can still be overridden.
. "$(dirname "$0")/local_https_server.sh"
export no_proxy="127.0.0.1,localhost${no_proxy:+,$no_proxy}" NO_PROXY="127.0.0.1,localhost${NO_PROXY:+,$NO_PROXY}"
HTTP_URL="${WGET_HTTP_URL:-http://127.0.0.1:$LOCAL_PORT/}"
HTTP_MATCH="smoke-ok"
HTTPS_URL="${WGET_HTTPS_URL:-https://127.0.0.1:$LOCAL_SSL_PORT/}"
HTTPS_MATCH="smoke-ok"
GZIP_URL="${WGET_GZIP_URL:-https://127.0.0.1:$LOCAL_SSL_PORT/}"
GZIP_MATCH="</html>"

RUN_INSTRUMENTED=1
RUN_BASELINE=1
USE_PROXY=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --instrumented-only) RUN_BASELINE=0; shift;;
        --baseline-only)     RUN_INSTRUMENTED=0; shift;;
        --no-proxy)          USE_PROXY=0; shift;;
        *) echo "Unknown option: $1" >&2; exit 1;;
    esac
done

if [ "$USE_PROXY" -eq 1 ] && [ -n "$PROXY" ]; then
    export http_proxy="$PROXY" https_proxy="$PROXY"
    PROXY_DESC="$PROXY"
else
    unset http_proxy https_proxy
    PROXY_DESC="(direct, no proxy)"
fi

echo "======================================================================"
echo "wget smoke test (client = variant; server = local baseline lighttpd)"
echo "  proxy: $PROXY_DESC"
echo "======================================================================"
echo ""

# fetch_ok <bin> <libs> <label> <match> <wget-args...>
# Runs wget; passes iff exit 0 AND the expected substring is in the body.
fetch_ok() {
    _bin="$1"; _libs="$2"; _label="$3"; _match="$4"; shift 4
    _body=$(LD_LIBRARY_PATH="$_libs" "$_bin" --timeout=25 --tries=1 -qO- "$@" 2>/dev/null) || _body=""
    if printf '%s' "$_body" | grep -q "$_match"; then
        echo "    ok   $_label"
        return 0
    else
        echo "    FAIL $_label (expected '$_match' in response)" >&2
        return 1
    fi
}

# smoke_one <variant>  (variant = instrumented | baseline)
smoke_one() {
    variant="$1"
    bin="$WKSP/$variant/wget"
    libs="$WKSP/$variant"

    echo "--- $variant ---"
    if [ ! -x "$bin" ]; then
        echo "    FAIL wget binary missing: $bin" >&2
        return 1
    fi

    rc=0
    fetch_ok "$bin" "$libs" "HTTP  GET  $HTTP_URL"  "$HTTP_MATCH"  "$HTTP_URL"  || rc=1
    fetch_ok "$bin" "$libs" "HTTPS GET  $HTTPS_URL  [openssl seal boundary]" \
             "$HTTPS_MATCH" --no-check-certificate "$HTTPS_URL" || rc=1
    fetch_ok "$bin" "$libs" "HTTPS gzip $GZIP_URL  [zlib seal boundary]" \
             "$GZIP_MATCH" --no-check-certificate --compression=gzip "$GZIP_URL" || rc=1

    if [ "$rc" -eq 0 ]; then
        echo "    PASS $variant"
    else
        echo "    FAIL $variant" >&2
    fi
    return $rc
}

start_local_server || exit 1
trap stop_local_server EXIT INT TERM

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
