#!/usr/bin/env bash
# ==============================================================================
# tests/test_coolify_adapter.sh - Deep Verification of Coolify & Standalone Adapters
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DRY_RUN=1

echo ">>> [1/5] Syntax check for Coolify & Standalone adapters..."
bash -n "$SCRIPT_DIR/adapters/coolify.sh"
bash -n "$SCRIPT_DIR/adapters/standalone.sh"
echo "Syntax checks passed ✅"

echo ">>> [2/5] Testing --help flag for Coolify adapter..."
"$SCRIPT_DIR/adapters/coolify.sh" --help >/dev/null
echo "Help flag works ✅"

echo ">>> [3/5] Testing validation on missing arguments..."
if "$SCRIPT_DIR/adapters/coolify.sh" 2>/dev/null; then
    echo "❌ Expected error on missing arguments, but succeeded!"
    exit 1
fi
if "$SCRIPT_DIR/adapters/coolify.sh" --panel-url "https://coolify.example.com" 2>/dev/null; then
    echo "❌ Expected error when --api-key is missing, but succeeded!"
    exit 1
fi
if "$SCRIPT_DIR/adapters/coolify.sh" --api-key "test_key" 2>/dev/null; then
    echo "❌ Expected error when --panel-url is missing, but succeeded!"
    exit 1
fi
echo "Argument validation passed ✅"

echo ">>> [4/5] Testing URL normalization and dry-run execution..."
output=$("$SCRIPT_DIR/adapters/coolify.sh" \
    --panel-url "https://coolify.example.com/" \
    --api-key "bearer_test_token" \
    --name "my-coolify-node" \
    --port 2222 \
    --user cooladmin)

echo "$output" | grep -q "Target Coolify URL: https://coolify.example.com" || {
    echo "❌ Trailing slash was not normalized"; exit 1;
}
echo "$output" | grep -q "my-coolify-node (cooladmin@port:2222)" || {
    echo "❌ Node identity formatting failed"; exit 1;
}
echo "$output" | grep -q "/api/v1/security/keys" || {
    echo "❌ Expected /api/v1/security/keys in dry run"; exit 1;
}
echo "$output" | grep -q "/api/v1/servers" || {
    echo "❌ Expected /api/v1/servers in dry run"; exit 1;
}
echo "Coolify adapter dry-run passed ✅"

echo ">>> [5/5] Testing adapters/standalone.sh..."
stand_out=$("$SCRIPT_DIR/adapters/standalone.sh")
echo "$stand_out" | grep -q "Standalone Node Configuration" || {
    echo "❌ Standalone adapter missing header"; exit 1;
}
echo "$stand_out" | grep -q "independent Docker Compose host" || {
    echo "❌ Standalone adapter missing host description"; exit 1;
}
echo "Standalone adapter passed ✅"

echo "✅ All Coolify and Standalone adapter tests passed successfully!"
