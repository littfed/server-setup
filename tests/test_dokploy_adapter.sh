#!/usr/bin/env bash
# ==============================================================================
# tests/test_dokploy_adapter.sh - Test Dokploy Adapter in Dry-Run Mode
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DRY_RUN=1

echo ">>> Testing adapters/dokploy.sh with missing args (should fail)..."
if "$SCRIPT_DIR/adapters/dokploy.sh" 2>/dev/null; then
    echo "Expected error on missing arguments, but succeeded!"
    exit 1
fi

echo ">>> Testing adapters/dokploy.sh in dry-run mode with valid args..."
"$SCRIPT_DIR/adapters/dokploy.sh" --panel-url "https://dokploy.example.com" --api-key "test_key" --name "test-node"

echo "✅ Dokploy adapter dry-run tests passed!"
