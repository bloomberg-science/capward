#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# test_wget.sh — PARITY test: the instrumented wget must match the baseline
#                wget per scenario, outcome for outcome.
#
# Methodology (same as test_nginx.sh): we do NOT assert absolute success — the
# network, proxy, or a remote site can make a fetch fail for reasons unrelated
# to sealing. We assert that our seal instrumentation does not CHANGE any
# scenario's outcome vs the baseline:
#   baseline pass + instrumented pass -> parity     (ok)
#   baseline fail + instrumented fail -> parity     (ok — flaky net / negative case)
#   baseline pass + instrumented fail -> REGRESSION (our fault; hard fail)
#   any other mismatch                -> differs    (flagged, investigate)
# Overall PASS iff zero regressions. Network flakiness fails BOTH variants, so
# it registers as parity, never a false regression.
#
# wget is the only instrumented binary and it is a CLIENT: scenarios fetch real
# servers on the internet through an HTTP proxy, if one is configured. Both binaries come from
# our pipeline (differ only by the seal pass), each run under its own
# LD_LIBRARY_PATH. Use smoke_wget.sh first for a fast liveness check.
#
# Scenarios exercise: wget core (HTTP), wget<->openssl (HTTPS handshake, forced
# TLS1.2, spider/HEAD, redirect->TLS), wget<->zlib (gzip), file write, and an
# error path (404).
#
# Usage:
#   ./test_wget.sh                      # parity: run both, compare per scenario
#   ./test_wget.sh --baseline-only      # just list baseline outcomes
#   ./test_wget.sh --instrumented-only  # just list instrumented outcomes
#   HTTP_PROXY_URL=http://host:port ./test_wget.sh
#   ./test_wget.sh --no-proxy

set -e

REPO_DIR="${REPO_DIR:-$HOME/capward}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$REPO_DIR/workspace}"
WKSP="$WORKSPACE_DIR/wget"
BASELINE_BINARY="$WKSP/baseline/wget"
BASELINE_LIBS="$WKSP/baseline"
INSTRUMENTED_BINARY="$WKSP/instrumented/wget"
INSTRUMENTED_LIBS="$WKSP/instrumented"
# Empty = direct connection. Set HTTP_PROXY_URL if your network needs a proxy.
PROXY="${HTTP_PROXY_URL:-}"

# Scenario ids (see run_scenario for each one's URL / args / expected content).
SCENARIOS="http https gzip tls12 redirect spider tofile notfound"

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
    export http_proxy="$PROXY" https_proxy="$PROXY"
    PROXY_DESC="$PROXY"
else
    unset http_proxy https_proxy
    PROXY_DESC="(direct, no proxy)"
fi

# run_scenario <binary> <libdir> <id> -> prints: pass | fail | missing
# pass = wget exit 0 AND the scenario's expected substring is present (in body,
# or in the written file for 'tofile'). Scenarios with no body ('spider') pass
# on exit 0 alone. 'notfound' is a negative case: it "fails" on both variants
# (non-zero exit) and thus registers as parity.
run_scenario() {
    _bin="$1"; _libs="$2"; _id="$3"
    [ -f "$_bin" ] || { echo missing; return; }
    W="--timeout=25 --tries=1 -q"
    _rc=0
    case "$_id" in
        http)
            _o=$(LD_LIBRARY_PATH="$_libs" "$_bin" $W -O- http://example.com/ 2>/dev/null) || _rc=$?
            _m="Example Domain";;
        https)
            _o=$(LD_LIBRARY_PATH="$_libs" "$_bin" $W --no-check-certificate -O- https://example.com/ 2>/dev/null) || _rc=$?
            _m="Example Domain";;
        gzip)
            _o=$(LD_LIBRARY_PATH="$_libs" "$_bin" $W --no-check-certificate --compression=gzip -O- https://www.gnu.org/ 2>/dev/null) || _rc=$?
            _m="</html>";;
        tls12)
            _o=$(LD_LIBRARY_PATH="$_libs" "$_bin" $W --no-check-certificate --secure-protocol=TLSv1_2 -O- https://example.com/ 2>/dev/null) || _rc=$?
            _m="Example Domain";;
        redirect)
            # http://www.gnu.org 301-redirects to https:// -> follow -> TLS fetch
            _o=$(LD_LIBRARY_PATH="$_libs" "$_bin" $W --no-check-certificate -O- http://www.gnu.org/ 2>/dev/null) || _rc=$?
            _m="</html>";;
        spider)
            LD_LIBRARY_PATH="$_libs" "$_bin" $W --no-check-certificate --spider https://example.com/ >/dev/null 2>&1 || _rc=$?
            _o=""; _m="";;
        tofile)
            _f=$(mktemp "/tmp/wget_tofile.XXXXXX")
            LD_LIBRARY_PATH="$_libs" "$_bin" $W --no-check-certificate -O "$_f" https://example.com/ >/dev/null 2>&1 || _rc=$?
            _o=$(cat "$_f" 2>/dev/null); rm -f "$_f"; _m="Example Domain";;
        notfound)
            _o=$(LD_LIBRARY_PATH="$_libs" "$_bin" $W --no-check-certificate -O- https://example.com/nonexistent-seal-test-xyz 2>/dev/null) || _rc=$?
            _m="Example Domain";;
        *) echo fail; return;;
    esac

    if [ "$_rc" -ne 0 ]; then echo fail; return; fi
    if [ -z "$_m" ]; then echo pass; return; fi
    if printf '%s' "$_o" | grep -q "$_m"; then echo pass; else echo fail; fi
}

echo "======================================================================"
echo "wget parity test (instrumented vs baseline, per scenario)"
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
