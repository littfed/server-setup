#!/usr/bin/env bash
# ==============================================================================
# tests/test_cli.sh - Deep Verification of CLI Dispatcher & Bundled Installer
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo ">>> [1/7] Syntax checks for setup.sh and bundle.sh..."
bash -n "$SCRIPT_DIR/setup.sh"
bash -n "$SCRIPT_DIR/bundle.sh"
echo "Syntax checks passed ✅"

echo ">>> [2/7] Testing setup.sh --help..."
help_out=$("$SCRIPT_DIR/setup.sh" --help)
echo "$help_out" | grep -q -- "--secure" || { echo "❌ Missing --secure in help"; exit 1; }
echo "$help_out" | grep -q -- "--harden-ssh" || { echo "❌ Missing --harden-ssh in help"; exit 1; }
echo "$help_out" | grep -q -- "--firewall" || { echo "❌ Missing --firewall in help"; exit 1; }
echo "$help_out" | grep -q -- "--ids" || { echo "❌ Missing --ids in help"; exit 1; }
echo "Help flags verified ✅"

echo ">>> [3/7] Testing validation errors for invalid or missing options..."
# Unknown option should fail
if "$SCRIPT_DIR/setup.sh" --invalid-flag-xyz 2>/dev/null; then
    echo "❌ Expected error on unknown flag, but succeeded!"
    exit 1
fi

# Dokploy missing credentials should fail
if "$SCRIPT_DIR/setup.sh" --dry-run --panel dokploy 2>/dev/null; then
    echo "❌ Expected error on --panel dokploy without credentials!"; exit 1;
fi

# Cloudflare missing token should fail
if "$SCRIPT_DIR/setup.sh" --dry-run --ingress cloudflare 2>/dev/null; then
    echo "❌ Expected error on --ingress cloudflare without token!"; exit 1;
fi
echo "Error and validation branches passed ✅"

echo ">>> [4/7] Testing setup.sh with standalone mode in dry-run..."
"$SCRIPT_DIR/setup.sh" --dry-run --panel standalone
echo "Standalone dry-run passed ✅"

echo ">>> [5/7] Testing setup.sh with Dokploy + full security stack in dry-run..."
"$SCRIPT_DIR/setup.sh" --dry-run \
  --panel dokploy \
  --panel-url "https://dokploy.example.com" \
  --api-key "test_key_123" \
  --name "test-node" \
  --secure \
  --ssh-port 2222 \
  --open-ports 8080 \
  --ingress cloudflare \
  --cf-token "test_cf_token" \
  --auto-prune \
  --prune-age 72h \
  --telemetry webhook \
  --webhook-url "https://test.example.com/webhook"
echo "Dokploy + full security stack dry-run passed ✅"

echo ">>> [6/7] Testing setup.sh with Coolify + selective security in dry-run..."
"$SCRIPT_DIR/setup.sh" --dry-run \
  --panel coolify \
  --panel-url "https://coolify.example.com" \
  --api-key "test_cool_token" \
  --name "cool-node" \
  --harden-ssh \
  --firewall \
  --ids fail2ban \
  --ingress caddy \
  --domain "cool.domain.com"
echo "Coolify + selective security dry-run passed ✅"

echo ">>> [7/7] Testing bundle build and standalone execution..."
"$SCRIPT_DIR/bundle.sh"
bundle_standalone="$SCRIPT_DIR/dist/server-setup-standalone.sh"
[ -x "$bundle_standalone" ] || { echo "❌ Bundled file not executable"; exit 1; }

"$bundle_standalone" --dry-run --panel standalone --secure
echo "Bundled standalone executable passed ✅"

echo "🎉 All CLI dispatcher and bundle tests passed successfully!"
