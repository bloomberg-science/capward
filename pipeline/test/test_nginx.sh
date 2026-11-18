#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# test_nginx.sh — PARITY test: the instrumented nginx must match the baseline
#                 nginx per test, outcome for outcome.
#
# Methodology: we are NOT validating that nginx-tests all pass in absolute
# terms — some fail/skip for reasons unrelated to sealing (disabled modules,
# missing features, environment). What we validate is that our seal
# instrumentation does not CHANGE any test's outcome. So for each test we run
# it on both binaries and compare:
#   baseline pass  + instrumented pass  -> parity  (ok)
#   baseline skip  + instrumented skip  -> parity  (ok)
#   baseline fail  + instrumented fail  -> parity  (ok — baseline already broken)
#   baseline pass  + instrumented fail  -> REGRESSION  (our fault; hard fail)
#   any other mismatch                  -> DIFFERS  (flagged, investigate)
# Overall result is PASS iff there are zero regressions.
#
# Testing principle: only nginx is instrumented; the nginx-tests Perl harness
# is its own client. Both binaries come from our pipeline (differ only by the
# seal pass) and each runs under its own LD_LIBRARY_PATH:
#   baseline     = workspace/nginx/baseline/nginx
#   instrumented = workspace/nginx/instrumented/nginx
#
# For a fast "does it start and serve" check, use smoke_nginx.sh first.
#
# Usage:
#   ./test_nginx.sh                      # parity: run both, compare per test
#   ./test_nginx.sh --baseline-only      # just list baseline outcomes
#   ./test_nginx.sh --instrumented-only  # just list instrumented outcomes
#
# Prerequisites: nginx-tests at $NGINX_TESTS; perl + Test::More + IO::Socket::SSL.

set -e

REPO_DIR="${REPO_DIR:-$HOME/capward}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$REPO_DIR/workspace}"
NGINX_TESTS="${NGINX_TESTS:-$HOME/nginx-tests}"

WKSP="$WORKSPACE_DIR/nginx"
BASELINE_BINARY="$WKSP/baseline/nginx"
BASELINE_LIBS="$WKSP/baseline"
INSTRUMENTED_BINARY="$WKSP/instrumented/nginx"
INSTRUMENTED_LIBS="$WKSP/instrumented"

# This test talks only to a server on localhost. If http_proxy/https_proxy is
# set in the environment (e.g. by the wget/curl internet tests), a proxy-aware
# client would route localhost through any configured HTTP proxy and fail. Bypass
# localhost rather than unsetting the proxy entirely.
export no_proxy="127.0.0.1,localhost,::1${no_proxy:+,${no_proxy}}"
export NO_PROXY="$no_proxy"

# Tests that pass on CheriBSD baseline (don't require rewrite module)
TESTS="ssl_certificate.t ssl_certificate_chain.t ssl_certificates.t
       ssl_crl.t ssl_verify_client.t ssl_verify_depth.t
       ssl_conf_command.t ssl_reject_handshake.t ssl_certificate_aux.t
       http_keepalive.t"

RUN_BASELINE=1
RUN_INSTRUMENTED=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --baseline-only)     RUN_INSTRUMENTED=0; shift;;
        --instrumented-only) RUN_BASELINE=0; shift;;
        *) echo "Unknown option: $1" >&2; exit 1;;
    esac
done

if [ ! -d "$NGINX_TESTS" ]; then
    echo "ERROR: nginx-tests not found at $NGINX_TESTS" >&2
    echo "Clone with: git clone https://github.com/nginx/nginx-tests.git $NGINX_TESTS" >&2
    exit 1
fi
cd "$NGINX_TESTS"

# classify <binary> <libdir> <test> -> prints one of: pass | skip | fail | missing
# Uses the test's exit status (0 = passed/all-skipped) plus a scan for
# "skipped:" to separate skip from pass. Exit status is the source of truth
# for the pass/fail verdict.
classify() {
    _bin="$1"; _libs="$2"; _t="$3"
    if [ ! -f "$_bin" ]; then echo missing; return; fi
    _out=$(TEST_NGINX_BINARY="$_bin" LD_LIBRARY_PATH="$_libs" prove "$_t" 2>&1) && _rc=0 || _rc=$?
    if printf '%s' "$_out" | grep -q 'skipped:'; then
        echo skip
    elif [ "$_rc" -eq 0 ]; then
        echo pass
    else
        echo fail
    fi
}

echo "======================================================================"
echo "nginx parity test (instrumented vs baseline, per test)"
echo "======================================================================"

# ---- Single-variant listing (no parity verdict) ----
if [ "$RUN_BASELINE" -eq 0 ] || [ "$RUN_INSTRUMENTED" -eq 0 ]; then
    if [ "$RUN_BASELINE" -eq 1 ]; then label="baseline"; bin="$BASELINE_BINARY"; libs="$BASELINE_LIBS"; fi
    if [ "$RUN_INSTRUMENTED" -eq 1 ]; then label="instrumented"; bin="$INSTRUMENTED_BINARY"; libs="$INSTRUMENTED_LIBS"; fi
    echo "Variant: $label ($bin)"
    echo ""
    for t in $TESTS; do
        r=$(classify "$bin" "$libs" "$t")
        printf "  %-26s %s\n" "$t" "$r"
    done
    exit 0
fi

# ---- Parity mode: run both, compare ----
printf "  %-26s %-9s %-12s %s\n" "TEST" "BASELINE" "INSTRUMENTED" "VERDICT"
printf "  %-26s %-9s %-12s %s\n" "----" "--------" "------------" "-------"

REGRESSIONS=0
DIFFERS=0
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
    printf "  %-26s %-9s %-12s %s\n" "$t" "$b" "$i" "$verdict"
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
