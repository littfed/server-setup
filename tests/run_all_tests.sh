#!/usr/bin/env bash
# ==============================================================================
# tests/run_all_tests.sh - Run Complete Test Suite
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================================="
echo " Running server-setup automated test suite..."
echo "=========================================================="

FAILED=0

run_test() {
    local t="$1"
    echo ""
    echo "▶️ Running $(basename "$t")..."
    if "$t"; then
        echo "✅ PASS: $(basename "$t")"
    else
        echo "❌ FAIL: $(basename "$t")"
        FAILED=$((FAILED + 1))
    fi
}

run_test "$SCRIPT_DIR/test_core.sh"
run_test "$SCRIPT_DIR/test_dokploy_adapter.sh"
run_test "$SCRIPT_DIR/test_coolify_adapter.sh"
run_test "$SCRIPT_DIR/test_auto_prune.sh"
run_test "$SCRIPT_DIR/test_ingress.sh"
run_test "$SCRIPT_DIR/test_telemetry.sh"
run_test "$SCRIPT_DIR/test_audit.sh"
run_test "$SCRIPT_DIR/test_cli.sh"

echo ""
echo "=========================================================="
if [ "$FAILED" -eq 0 ]; then
    echo "🎉 ALL TESTS PASSED SUCCESSFULLY!"
    exit 0
else
    echo "❌ $FAILED TEST(S) FAILED!"
    exit 1
fi
