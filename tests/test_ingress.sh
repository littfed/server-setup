#!/usr/bin/env bash
# ==============================================================================
# tests/test_ingress.sh - Deep Verification of Ingress Modules (Cloudflare & Caddy)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DRY_RUN=1

echo ">>> [1/5] Syntax checks for ingress modules..."
bash -n "$SCRIPT_DIR/modules/ingress/cloudflare.sh"
bash -n "$SCRIPT_DIR/modules/ingress/caddy.sh"
echo "Syntax checks passed ✅"

echo ">>> [2/5] Testing --help flags..."
"$SCRIPT_DIR/modules/ingress/cloudflare.sh" --help >/dev/null
"$SCRIPT_DIR/modules/ingress/caddy.sh" --help >/dev/null
echo "Help flags work ✅"

echo ">>> [3/5] Testing Cloudflare Tunnel with token in dry-run..."
cf_out=$("$SCRIPT_DIR/modules/ingress/cloudflare.sh" --cf-token "test_cf_secret_token_123")
echo "$cf_out" | grep -q "cloudflared binary" || {
    echo "❌ Missing cloudflared binary check"; exit 1;
}
echo "$cf_out" | grep -q "cloudflared systemd service" || {
    echo "❌ Missing systemd service setup"; exit 1;
}
echo "Cloudflare Tunnel dry-run passed ✅"

echo ">>> [4/5] Testing Caddy ingress with custom domain and upstream..."
caddy_out=$("$SCRIPT_DIR/modules/ingress/caddy.sh" --domain "myapp.example.com" --upstream "10.0.0.5:8080")
echo "$caddy_out" | grep -q "myapp.example.com -> 10.0.0.5:8080" || {
    echo "❌ Custom domain/upstream mapping failed"; exit 1;
}
echo "$caddy_out" | grep -q "/etc/caddy/Caddyfile" || {
    echo "❌ Missing Caddyfile reference"; exit 1;
}
echo "$caddy_out" | grep -q "<20 MB RAM" || {
    echo "❌ Missing low-RAM footprint statement"; exit 1;
}
echo "Caddy ingress dry-run passed ✅"

echo ">>> [5/5] Testing ingress integration in setup.sh..."
setup_caddy=$("$SCRIPT_DIR/setup.sh" --dry-run --ingress caddy --domain "test.app" --upstream "127.0.0.1:4000")
echo "$setup_caddy" | grep -q "Configuring Caddy Ingress" || {
    echo "❌ setup.sh failed to invoke Caddy ingress"; exit 1;
}

setup_cf=$("$SCRIPT_DIR/setup.sh" --dry-run --ingress cloudflare --cf-token "tok123")
echo "$setup_cf" | grep -q "Configuring Cloudflare Tunnel Ingress" || {
    echo "❌ setup.sh failed to invoke Cloudflare ingress"; exit 1;
}
echo "Setup CLI ingress integration passed ✅"

echo "✅ All Ingress tests passed successfully!"
