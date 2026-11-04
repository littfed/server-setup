#!/usr/bin/env bash
# ==============================================================================
# tests/test_auto_prune.sh - Test Docker Auto-Prune Module in Dry-Run Mode
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DRY_RUN=1

echo ">>> Testing modules/maintenance/auto-prune.sh (install mode)..."
"$SCRIPT_DIR/modules/maintenance/auto-prune.sh"

echo ">>> Testing modules/maintenance/auto-prune.sh (run-now mode)..."
"$SCRIPT_DIR/modules/maintenance/auto-prune.sh" --run-now --filter-age 24h

echo "✅ Docker auto-prune dry-run tests passed!"
