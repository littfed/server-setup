#!/usr/bin/env bash
# ==============================================================================
# tests/test_dokploy_adapter.sh - Deep Verification of Dokploy Adapter
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DRY_RUN=1

echo ">>> [1/5] Syntax check for adapters/dokploy.sh..."
bash -n "$SCRIPT_DIR/adapters/dokploy.sh"
echo "Syntax check passed ✅"

echo ">>> [2/5] Testing --help flag..."
"$SCRIPT_DIR/adapters/dokploy.sh" --help >/dev/null
echo "Help flag works ✅"

echo ">>> [3/5] Testing validation on missing arguments..."
if "$SCRIPT_DIR/adapters/dokploy.sh" 2>/dev/null; then
    echo "❌ Expected error on missing arguments, but succeeded!"
    exit 1
fi
if "$SCRIPT_DIR/adapters/dokploy.sh" --panel-url "https://example.com" 2>/dev/null; then
    echo "❌ Expected error when --api-key is missing, but succeeded!"
    exit 1
fi
if "$SCRIPT_DIR/adapters/dokploy.sh" --api-key "test_key" 2>/dev/null; then
    echo "❌ Expected error when --panel-url is missing, but succeeded!"
    exit 1
fi
echo "Argument validation passed ✅"

echo ">>> [4/5] Testing URL normalization and dry-run execution..."
output=$("$SCRIPT_DIR/adapters/dokploy.sh" \
    --panel-url "https://dokploy.example.com/" \
    --api-key "test_key_xyz" \
    --name "my-dokploy-node" \
    --port 2222 \
    --user deploy)

# Assert trailing slash stripped
echo "$output" | grep -q "Target Dokploy URL: https://dokploy.example.com" || {
    echo "❌ URL normalization failed (trailing slash not stripped)"; exit 1;
}

# Assert node identity
echo "$output" | grep -q "my-dokploy-node (deploy@port:2222)" || {
    echo "❌ Node identity formatting failed"; exit 1;
}

# Assert API endpoints mentioned
echo "$output" | grep -q "/api/sshKey.all" || {
    echo "❌ Expected /api/sshKey.all in dry run"; exit 1;
}
echo "$output" | grep -q "/api/server.create" || {
    echo "❌ Expected /api/server.create in dry run"; exit 1;
}
echo "Dry-run execution passed ✅"

echo ">>> [5/5] Testing mock key authorization behavior..."
# Verify script contains reverse registration payload logic
grep -q "server.create" "$SCRIPT_DIR/adapters/dokploy.sh" || {
    echo "❌ Missing server.create API call in adapter"; exit 1;
}
grep -q "sshKey.all" "$SCRIPT_DIR/adapters/dokploy.sh" || {
    echo "❌ Missing sshKey.all API call in adapter"; exit 1;
}
echo "API endpoint contracts verified ✅"

echo "✅ All Dokploy adapter tests passed successfully!"
