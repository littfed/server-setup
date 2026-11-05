#!/usr/bin/env bash
# ==============================================================================
# tests/test_telemetry.sh - Deep Verification of Zero-Overhead Telemetry Module
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo ">>> [1/5] Syntax check for modules/telemetry/health-cron.sh..."
bash -n "$SCRIPT_DIR/modules/telemetry/health-cron.sh"
echo "Syntax check passed ✅"

echo ">>> [2/5] Testing --help flag..."
"$SCRIPT_DIR/modules/telemetry/health-cron.sh" --help >/dev/null
echo "Help flag works ✅"

echo ">>> [3/5] Testing metrics sampling and schema validation..."
output="$("$SCRIPT_DIR/modules/telemetry/health-cron.sh")"

# Must be parseable JSON
echo "$output" | jq . >/dev/null || {
    echo "❌ Metrics output is not valid JSON"; exit 1;
}

# Verify required keys exist
host=$(echo "$output" | jq -r '.host')
ts=$(echo "$output" | jq -r '.timestamp')
mem_pct=$(echo "$output" | jq -r '.metrics.memory_used_pct')
disk_pct=$(echo "$output" | jq -r '.metrics.disk_used_pct')
mem_tot=$(echo "$output" | jq -r '.metrics.memory_total_mb')
load_1m=$(echo "$output" | jq -r '.metrics.load_1m')

if [ -z "$host" ] || [ "$host" = "null" ]; then
    echo "❌ Missing host key in telemetry JSON"; exit 1;
fi
if [ -z "$ts" ] || [ "$ts" = "null" ]; then
    echo "❌ Missing timestamp key in telemetry JSON"; exit 1;
fi

# Value ranges
if [ "$mem_pct" -lt 0 ] || [ "$mem_pct" -gt 100 ]; then
    echo "❌ memory_used_pct ($mem_pct) out of bounds [0, 100]"; exit 1;
fi
if [ "$disk_pct" -lt 0 ] || [ "$disk_pct" -gt 100 ]; then
    echo "❌ disk_used_pct ($disk_pct) out of bounds [0, 100]"; exit 1;
fi
if [ "$mem_tot" -le 0 ]; then
    echo "❌ memory_total_mb ($mem_tot) must be positive"; exit 1;
fi
echo "Metrics schema & boundary checks passed ✅"

echo ">>> [4/5] Testing --send-now in dry-run mode..."
send_out=$(DRY_RUN=1 "$SCRIPT_DIR/modules/telemetry/health-cron.sh" --send-now --webhook-url "https://api.example.com/health")
echo "$send_out" | grep -q "Sampled payload" || {
    echo "❌ Missing sampled payload in send-now dry-run"; exit 1;
}
echo "Send-now dry run passed ✅"

echo ">>> [5/5] Testing --install-cron in dry-run mode..."
cron_out=$(DRY_RUN=1 "$SCRIPT_DIR/modules/telemetry/health-cron.sh" --install-cron --interval 10 --webhook-url "https://api.example.com/health")
echo "$cron_out" | grep -q "every 10 min" || {
    echo "❌ Missing custom interval in cron installation"; exit 1;
}
echo "$cron_out" | grep -q "/etc/cron.d/server-setup-telemetry" || {
    echo "❌ Missing cron file target in output"; exit 1;
}
echo "Install-cron dry run passed ✅"

echo "✅ All Telemetry module tests passed successfully!"
