#!/usr/bin/env bash
# ==============================================================================
# tests/test_ingress.sh - Test Ingress Modules (Cloudflare & Caddy) in Dry-Run
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DRY_RUN=1

echo ">>> Testing modules/ingress/cloudflare.sh..."
"$SCRIPT_DIR/modules/ingress/cloudflare.sh" --cf-token "test_token_123"

echo ">>> Testing modules/ingress/caddy.sh..."
"$SCRIPT_DIR/modules/ingress/caddy.sh" --domain "app.example.com" --upstream "127.0.0.1:8080"

echo "✅ Ingress dry-run tests passed!"
