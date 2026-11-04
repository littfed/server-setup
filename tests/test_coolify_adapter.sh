#!/usr/bin/env bash
# ==============================================================================
# tests/test_coolify_adapter.sh - Test Coolify Adapter in Dry-Run Mode
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DRY_RUN=1

echo ">>> Testing adapters/coolify.sh with missing args (should fail)..."
if "$SCRIPT_DIR/adapters/coolify.sh" 2>/dev/null; then
    echo "Expected failure on missing arguments, but succeeded!"
    exit 1
fi

echo ">>> Testing adapters/coolify.sh in dry-run mode with valid args..."
"$SCRIPT_DIR/adapters/coolify.sh" --panel-url "https://coolify.example.com" --api-key "test_token" --name "cool-node"

echo ">>> Testing adapters/standalone.sh..."
"$SCRIPT_DIR/adapters/standalone.sh"

echo "✅ Coolify and Standalone adapter dry-run tests passed!"
