#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# test_curl.sh — PARITY test: the instrumented curl must match the baseline
#                curl per scenario, outcome for outcome.
#
# Methodology (same as test_wget.sh / test_nginx.sh): we do NOT assert absolute
# success — the network, proxy, or a remote site can make a fetch fail for
# reasons unrelated to sealing. We assert that our seal instrumentation does not
# CHANGE any scenario's outcome vs the baseline:
#   baseline pass + instrumented pass -> parity     (ok)
#   baseline fail + instrumented fail -> parity     (ok — flaky net / negative case)
#   baseline pass + instrumented fail -> REGRESSION (our fault; hard fail)
#   any other mismatch                -> differs    (flagged, investigate)
# Overall PASS iff zero regressions. Network flakiness fails BOTH variants, so
# it registers as parity, never a false regression.
#
# curl is the only instrumented binary and it is a CLIENT: scenarios fetch real
# servers through an HTTP proxy, if one is configured. libcurl is statically linked into curl,
# so each variant only needs LD_LIBRARY_PATH for its sealed libssl/libz. Use
# smoke_curl.sh first for a fast liveness check.
#
# Scenarios exercise: curl core (HTTP), curl<->openssl (HTTPS handshake, forced
# TLS1.2, HEAD, redirect->TLS), curl<->zlib (gzip), file write, error path (404).
#
# Usage:
#   ./test_curl.sh                      # parity: run both, compare per scenario
#   ./test_curl.sh --baseline-only      # just list baseline outcomes
#   ./test_curl.sh --instrumented-only  # just list instrumented outcomes
#   HTTP_PROXY_URL=http://host:port ./test_curl.sh
#   ./test_curl.sh --no-proxy

set -e

REPO_DIR="${REPO_DIR:-$HOME/capward}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$REPO_DIR/workspace}"
WKSP="$WORKSPACE_DIR/curl"
BASELINE_BINARY="$WKSP/baseline/curl"
BASELINE_LIBS="$WKSP/baseline"
INSTRUMENTED_BINARY="$WKSP/instrumented/curl"
INSTRUMENTED_LIBS="$WKSP/instrumented"
# Empty = direct connection. Set HTTP_PROXY_URL if your network needs a proxy.
PROXY="${HTTP_PROXY_URL:-}"

# Scenario ids (see run_scenario for each one's URL / args / expected content).
SCENARIOS="http https gzip tls12 redirect head tofile notfound"

RUN_BASELINE=1
RUN_INSTRUMENTED=1
USE_PROXY=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --baseline-only)     RUN_INSTRUMENTED=0; shift;;
        --instrumented-only) RUN_BASELINE=0; shift;;
        --no-proxy)          USE_PROXY=0; shift;;
        *) echo "Unknown option: $1" >&2; exit 1;;
    esac
done

if [ "$USE_PROXY" -eq 1 ] && [ -n "$PROXY" ]; then
    PROXY_ARGS="-x $PROXY"
    PROXY_DESC="$PROXY"
else
    PROXY_ARGS=""
    PROXY_DESC="(direct, no proxy)"
fi

# run_scenario <binary> <libdir> <id> -> prints: pass | fail | missing
# pass = curl exit 0 AND the scenario's expected substring is present (in body,
# or the written file for 'tofile'; 'head' matches the status line). 'notfound'
# is a negative case: curl -f exits non-zero on 404, so both variants "fail" and
# it registers as parity.
run_scenario() {
    _bin="$1"; _libs="$2"; _id="$3"
    [ -f "$_bin" ] || { echo missing; return; }
    C="-s --max-time 25 $PROXY_ARGS"
    _rc=0
    case "$_id" in
        http)
            _o=$(LD_LIBRARY_PATH="$_libs" "$_bin" $C http://example.com/ 2>/dev/null) || _rc=$?
            _m="Example Domain";;
        https)
            _o=$(LD_LIBRARY_PATH="$_libs" "$_bin" $C -k https://example.com/ 2>/dev/null) || _rc=$?
            _m="Example Domain";;
        gzip)
            _o=$(LD_LIBRARY_PATH="$_libs" "$_bin" $C -k --compressed https://www.gnu.org/ 2>/dev/null) || _rc=$?
            _m="</html>";;
        tls12)
            _o=$(LD_LIBRARY_PATH="$_libs" "$_bin" $C -k --tlsv1.2 https://example.com/ 2>/dev/null) || _rc=$?
            _m="Example Domain";;
        redirect)
            # http://www.gnu.org 301-redirects to https:// -> follow (-L) -> TLS fetch
            _o=$(LD_LIBRARY_PATH="$_libs" "$_bin" $C -k -L http://www.gnu.org/ 2>/dev/null) || _rc=$?
            _m="</html>";;
        head)
            _o=$(LD_LIBRARY_PATH="$_libs" "$_bin" $C -k -I https://example.com/ 2>/dev/null) || _rc=$?
            _m="HTTP/";;
        tofile)
            _f=$(mktemp "/tmp/curl_tofile.XXXXXX")
            LD_LIBRARY_PATH="$_libs" "$_bin" $C -k -o "$_f" https://example.com/ >/dev/null 2>&1 || _rc=$?
            _o=$(cat "$_f" 2>/dev/null); rm -f "$_f"; _m="Example Domain";;
        notfound)
            # -f: fail (non-zero) on HTTP >= 400. Both variants should fail -> parity.
            _o=$(LD_LIBRARY_PATH="$_libs" "$_bin" $C -k -f https://example.com/nonexistent-seal-test-xyz 2>/dev/null) || _rc=$?
            _m="Example Domain";;
        *) echo fail; return;;
    esac

    if [ "$_rc" -ne 0 ]; then echo fail; return; fi
    if [ -z "$_m" ]; then echo pass; return; fi
    if printf '%s' "$_o" | grep -q "$_m"; then echo pass; else echo fail; fi
}

echo "======================================================================"
echo "curl parity test (instrumented vs baseline, per scenario)"
echo "  proxy: $PROXY_DESC"
echo "======================================================================"

# ---- Single-variant listing (no parity verdict) ----
if [ "$RUN_BASELINE" -eq 0 ] || [ "$RUN_INSTRUMENTED" -eq 0 ]; then
    if [ "$RUN_BASELINE" -eq 1 ]; then label="baseline"; bin="$BASELINE_BINARY"; libs="$BASELINE_LIBS"; fi
    if [ "$RUN_INSTRUMENTED" -eq 1 ]; then label="instrumented"; bin="$INSTRUMENTED_BINARY"; libs="$INSTRUMENTED_LIBS"; fi
    echo "Variant: $label ($bin)"
    echo ""
    for s in $SCENARIOS; do
        r=$(run_scenario "$bin" "$libs" "$s")
        printf "  %-12s %s\n" "$s" "$r"
    done
    exit 0
fi

# ---- Parity mode: run both, compare ----
printf "  %-12s %-9s %-12s %s\n" "SCENARIO" "BASELINE" "INSTRUMENTED" "VERDICT"
printf "  %-12s %-9s %-12s %s\n" "--------" "--------" "------------" "-------"

REGRESSIONS=0
DIFFERS=0
for s in $SCENARIOS; do
    b=$(run_scenario "$BASELINE_BINARY" "$BASELINE_LIBS" "$s")
    i=$(run_scenario "$INSTRUMENTED_BINARY" "$INSTRUMENTED_LIBS" "$s")

    if [ "$b" = "$i" ]; then
        verdict="parity"
    elif [ "$b" = "pass" ] && [ "$i" = "fail" ]; then
        verdict="** REGRESSION **"; REGRESSIONS=$((REGRESSIONS + 1))
    else
        verdict="differs"; DIFFERS=$((DIFFERS + 1))
    fi
    printf "  %-12s %-9s %-12s %s\n" "$s" "$b" "$i" "$verdict"
done

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
