#!/usr/bin/env bash
# ==============================================================================
# tests/test_speedtest.sh - Verification of Multi-Stream Speedtest Engine
# Tests: modules/diagnostics/speedtest.sh, setup.sh --speedtest, and standalone
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DRY_RUN=1

echo ">>> [1/6] Syntax checks for speedtest module..."
bash -n "$SCRIPT_DIR/modules/diagnostics/speedtest.sh"
echo "Syntax check passed ✅"

echo ">>> [2/6] Testing --help flag..."
"$SCRIPT_DIR/modules/diagnostics/speedtest.sh" --help >/dev/null
echo "Help flag works ✅"

echo ">>> [3/6] Testing modules/diagnostics/speedtest.sh in dry-run mode..."
dry_out="$("$SCRIPT_DIR/modules/diagnostics/speedtest.sh" --dry-run)"
echo "$dry_out" | grep -q "NETWORK SPEEDTEST & BANDWIDTH REPORT" || {
    echo "❌ Missing report header in speedtest output"; exit 1;
}
echo "$dry_out" | grep -q "Download Bandwidth" || {
    echo "❌ Missing download bandwidth in speedtest output"; exit 1;
}
echo "$dry_out" | grep -q "Upload Bandwidth" || {
    echo "❌ Missing upload bandwidth in speedtest output"; exit 1;
}
echo "$dry_out" | grep -q "Mbit/s" || {
    echo "❌ Missing Mbit/s metric in speedtest output"; exit 1;
}
echo "modules/diagnostics/speedtest.sh dry-run passed ✅"

echo ">>> [4/6] Testing JSON output and schema validation..."
json_out="$("$SCRIPT_DIR/modules/diagnostics/speedtest.sh" --dry-run --json)"
echo "$json_out" | jq -e '.speedtest.download_mbps' >/dev/null || {
    echo "❌ Missing download_mbps in speedtest JSON"; exit 1;
}
echo "$json_out" | jq -e '.speedtest.upload_mbps' >/dev/null || {
    echo "❌ Missing upload_mbps in speedtest JSON"; exit 1;
}
echo "$json_out" | jq -e '.speedtest.streams' >/dev/null || {
    echo "❌ Missing streams count in speedtest JSON"; exit 1;
}
echo "$json_out" | jq -e '.speedtest.jitter_ms' >/dev/null || {
    echo "❌ Missing jitter in speedtest JSON"; exit 1;
}
echo "JSON schema validation passed ✅"

echo ">>> [5/6] Testing setup.sh --speedtest integration..."
setup_out="$("$SCRIPT_DIR/setup.sh" --speedtest --dry-run)"
echo "$setup_out" | grep -q "NETWORK SPEEDTEST & BANDWIDTH REPORT" || {
    echo "❌ setup.sh --speedtest failed"; exit 1;
}
echo "setup.sh --speedtest passed ✅"

echo ">>> [6/6] Testing standalone bundle --speedtest execution..."
bundle_out="$("$SCRIPT_DIR/dist/server-setup-standalone.sh" --speedtest --dry-run)"
echo "$bundle_out" | grep -q "NETWORK SPEEDTEST & BANDWIDTH REPORT" || {
    echo "❌ dist/server-setup-standalone.sh --speedtest failed"; exit 1;
}
echo "Standalone bundle speedtest passed ✅"

echo "✅ All Speedtest module tests passed successfully!"
