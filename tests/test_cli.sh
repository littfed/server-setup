#!/usr/bin/env bash
# ==============================================================================
# tests/test_cli.sh - Test Unified CLI Dispatcher and Standalone Bundle
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo ">>> [1/4] Testing setup.sh --help..."
"$SCRIPT_DIR/setup.sh" --help >/dev/null
echo "Help flag works ✅"

echo ">>> [2/4] Testing setup.sh with standalone mode in dry-run..."
"$SCRIPT_DIR/setup.sh" --dry-run --panel standalone
echo "Standalone dry-run works ✅"

echo ">>> [3/4] Testing setup.sh with all modules in dry-run..."
"$SCRIPT_DIR/setup.sh" --dry-run \
  --panel dokploy \
  --panel-url "https://dokploy.example.com" \
  --api-key "test_key_123" \
  --name "test-node" \
  --ingress cloudflare \
  --cf-token "test_cf_token" \
  --auto-prune \
  --prune-age 72h \
  --telemetry webhook \
  --webhook-url "https://test.example.com/webhook"
echo "Full stack dry-run works ✅"

echo ">>> [4/4] Testing standalone bundled installer dist/server-setup-standalone.sh..."
"$SCRIPT_DIR/dist/server-setup-standalone.sh" --dry-run --panel standalone
echo "Bundled standalone executable works ✅"

echo "🎉 All CLI dispatcher and bundle tests passed successfully!"
