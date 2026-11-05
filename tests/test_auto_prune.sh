#!/usr/bin/env bash
# ==============================================================================
# tests/test_auto_prune.sh - Deep Verification of Docker Auto-Prune Module
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DRY_RUN=1

echo ">>> [1/5] Syntax check for modules/maintenance/auto-prune.sh..."
bash -n "$SCRIPT_DIR/modules/maintenance/auto-prune.sh"
echo "Syntax check passed ✅"

echo ">>> [2/5] Testing --help flag..."
"$SCRIPT_DIR/modules/maintenance/auto-prune.sh" --help >/dev/null
echo "Help flag works ✅"

echo ">>> [3/5] Testing install mode in dry-run..."
install_out=$("$SCRIPT_DIR/modules/maintenance/auto-prune.sh")
echo "$install_out" | grep -q "docker-auto-prune.{service,timer}" || {
    echo "❌ Missing systemd service/timer in dry-run output"; exit 1;
}
echo "Install mode passed ✅"

echo ">>> [4/5] Testing run-now mode in dry-run..."
run_out=$("$SCRIPT_DIR/modules/maintenance/auto-prune.sh" --run-now --filter-age 24h)
echo "$run_out" | grep -q "nice -n 19 ionice -c 3 docker system prune -f --filter until=24h" || {
    echo "❌ Missing low-priority prune command in dry-run output"; exit 1;
}
echo "Run-now mode passed ✅"

echo ">>> [5/5] Testing threshold skipping logic..."
thresh_out=$("$SCRIPT_DIR/modules/maintenance/auto-prune.sh" --run-now --threshold 100)
echo "$thresh_out" | grep -q "Prune skipped" || {
    echo "❌ Expected prune to be skipped when threshold=100%"; exit 1;
}
echo "Threshold check passed ✅"

echo "✅ All Docker auto-prune tests passed successfully!"
