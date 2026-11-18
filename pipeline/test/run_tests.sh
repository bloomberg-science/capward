#!/bin/sh
# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# run_tests.sh — Run the functionality test suite for the six evaluated apps.
#
# Usage: ./run_tests.sh
#
# Scope matches build/run_seal_analysis.sh: nginx, lighttpd, memcached, redis,
# curl, wget. tar/opensmtpd/httpd are out of evaluation scope.

set -e

REPO_DIR="${REPO_DIR:-$HOME/capward}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$REPO_DIR/workspace}"
SCRIPTS_DIR="$REPO_DIR/pipeline/test"

echo "======================================================================"
echo "Running All Functionality Tests"
echo "======================================================================"
echo ""

PASS=0
FAIL=0
SKIP=0

run_test() {
    local app="$1"
    local script="$SCRIPTS_DIR/test_${app}.sh"
    if [ ! -f "$script" ]; then
        echo ">>> $app: SKIP (no test script)"
        SKIP=$((SKIP + 1))
        return
    fi
    echo ">>> $app"
    if sh "$script"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo ">>> $app: FAILED"
    fi
    echo ""
}

run_test redis
run_test wget
run_test curl
run_test lighttpd
run_test nginx
run_test memcached

echo "======================================================================"
echo "Summary: $PASS passed, $FAIL failed, $SKIP skipped"
echo "======================================================================"
