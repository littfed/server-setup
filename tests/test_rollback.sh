#!/usr/bin/env bash
# ==============================================================================
# tests/test_rollback.sh - Deep Verification of Rollback & Snapshot Engine
# Tests: modules/maintenance/rollback.sh and setup.sh --rollback
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DRY_RUN=1

echo ">>> [1/5] Syntax check for rollback script..."
bash -n "$SCRIPT_DIR/modules/maintenance/rollback.sh"
echo "Syntax check passed ✅"

echo ">>> [2/5] Testing --help flag..."
"$SCRIPT_DIR/modules/maintenance/rollback.sh" --help >/dev/null
echo "Help flag works ✅"

echo ">>> [3/5] Testing snapshot creation and list in dry-run..."
snap_out="$("$SCRIPT_DIR/modules/maintenance/rollback.sh" snapshot)"
echo "$snap_out" | grep -q "Would snapshot tracked configurations" || {
    echo "❌ Missing snapshot statement in dry-run output"; exit 1;
}

list_out="$("$SCRIPT_DIR/modules/maintenance/rollback.sh" list)"
echo "$list_out" | grep -q "Available Server-Setup Snapshots" || {
    echo "❌ Missing list header in rollback list output"; exit 1;
}
echo "Snapshot & list dry-run passed ✅"

echo ">>> [4/5] Testing restore in dry-run..."
restore_out="$("$SCRIPT_DIR/modules/maintenance/rollback.sh" restore latest)"
echo "$restore_out" | grep -q "Would identify latest snapshot and restore" || {
    echo "❌ Missing restore plan in dry-run output"; exit 1;
}
echo "Restore dry-run passed ✅"

echo ">>> [5/5] Testing setup.sh rollback options integration..."
setup_roll_list="$("$SCRIPT_DIR/setup.sh" --rollback-list)"
echo "$setup_roll_list" | grep -q "Available Server-Setup Snapshots" || {
    echo "❌ setup.sh --rollback-list failed"; exit 1;
}

setup_roll_res="$("$SCRIPT_DIR/setup.sh" --dry-run --rollback latest)"
echo "$setup_roll_res" | grep -q "Would identify latest snapshot" || {
    echo "❌ setup.sh --rollback latest failed"; exit 1;
}

bundle_roll="$("$SCRIPT_DIR/dist/server-setup-standalone.sh" --rollback-list)"
echo "$bundle_roll" | grep -q "Available Server-Setup Snapshots" || {
    echo "❌ standalone bundle rollback-list failed"; exit 1;
}
echo "setup.sh & standalone bundle rollback integration passed ✅"

echo "✅ All Rollback & Snapshot tests passed successfully!"
