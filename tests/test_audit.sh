#!/usr/bin/env bash
# ==============================================================================
# test_audit.sh - Unit and dry-run tests for IP Reputation Audit Module
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo ">>> [1/7] Checking bash syntax for modules/audit/ip-reputation.sh..."
bash -n "$PROJECT_ROOT/modules/audit/ip-reputation.sh"

echo ">>> [2/7] Testing --help flag..."
"$PROJECT_ROOT/modules/audit/ip-reputation.sh" --help >/dev/null

echo ">>> [3/7] Testing dry-run terminal output..."
output=$("$PROJECT_ROOT/modules/audit/ip-reputation.sh" --dry-run)
if ! echo "$output" | grep -q "IP REPUTATION & THREAT INTELLIGENCE AUDIT"; then
    echo "❌ Missing header in audit terminal output"
    exit 1
fi
if ! echo "$output" | grep -q "✓ IP is clean"; then
    echo "❌ Missing clean status confirmation"
    exit 1
fi

echo ">>> [4/7] Testing dry-run JSON format and jq parsing..."
json_out=$("$PROJECT_ROOT/modules/audit/ip-reputation.sh" --dry-run --json --no-save)
if ! echo "$json_out" | jq -e '.results[0].ip' >/dev/null; then
    echo "❌ Invalid JSON emitted by --json flag"
    exit 1
fi

status=$(echo "$json_out" | jq -r '.overall_status')
if [ "$status" != "CLEAN" ]; then
    echo "❌ Unexpected status: $status"
    exit 1
fi

echo ">>> [5/7] Testing custom IP and --dns override..."
dns_out=$("$PROJECT_ROOT/modules/audit/ip-reputation.sh" 1.2.3.4 --dns 9.9.9.9 --dry-run)
if ! echo "$dns_out" | grep -q "9.9.9.9"; then
    echo "❌ Custom DNS resolver 9.9.9.9 was not reflected in output"
    exit 1
fi

echo ">>> [6/7] Testing multiple IPs audit..."
multi_out=$("$PROJECT_ROOT/modules/audit/ip-reputation.sh" 1.1.1.1 8.8.8.8 --dry-run --json --no-save)
ip_count=$(echo "$multi_out" | jq '.results | length')
if [ "$ip_count" -ne 2 ]; then
    echo "❌ Expected 2 audited IPs, got $ip_count"
    exit 1
fi

echo ">>> [7/7] Testing integration in setup.sh with --audit-only and --strict-audit..."
setup_audit=$("$PROJECT_ROOT/setup.sh" --audit-only --dry-run)
if ! echo "$setup_audit" | grep -q "audit-only mode"; then
    echo "❌ setup.sh --audit-only failed to run"
    exit 1
fi

echo "✅ All IP reputation audit tests passed successfully!"
