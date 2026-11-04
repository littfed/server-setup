#!/usr/bin/env bash
# ==============================================================================
# tests/test_telemetry.sh - Test Zero-Overhead Telemetry Module
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo ">>> Testing sample_metrics directly..."
OUTPUT="$("$SCRIPT_DIR/modules/telemetry/health-cron.sh")"
echo "Metrics output:"
echo "$OUTPUT"

# Verify valid JSON
echo "$OUTPUT" | jq . >/dev/null
echo "Valid JSON confirmed ✅"

export DRY_RUN=1
echo ">>> Testing install mode in dry-run..."
"$SCRIPT_DIR/modules/telemetry/health-cron.sh" --install-cron --webhook-url "https://example.com/webhook"

echo "✅ Telemetry module tests passed!"
