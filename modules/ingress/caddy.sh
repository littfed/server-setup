#!/usr/bin/env bash
# ==============================================================================
# modules/ingress/caddy.sh - Lightweight Caddy Ingress with Automated Let's Encrypt
# Replaces heavy Traefik (80-100 MB RAM) with lean Caddy (<20 MB RAM)
# ==============================================================================

set -euo pipefail

log_info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
log_ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
log_err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

get_sudo() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "echo [dry-run]"
        return
    fi
    if [ "$EUID" -eq 0 ]; then
        echo ""
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        echo "sudo"
    else
        log_err "Non-root user requires passwordless sudo access."
        exit 1
    fi
}

SUDO_CMD="$(get_sudo)"

# 1. Setup Caddy configuration and container
setup_caddy_ingress() {
    local domain="${1:-localhost}"
    local upstream="${2:-127.0.0.1:3000}"

    log_info "Configuring Caddy reverse proxy for domain: $domain -> $upstream..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would create /etc/caddy/Caddyfile and run Caddy container (<20 MB RAM)"
        return 0
    fi

    $SUDO_CMD mkdir -p /etc/caddy
    cat <<EOF | $SUDO_CMD tee /etc/caddy/Caddyfile >/dev/null
{
    admin off
    auto_https disable_redirects
}

$domain {
    reverse_proxy $upstream
}
EOF

    # Run Caddy in lightweight container connected to host/dokploy-network
    if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
        if docker ps -a --format '{{.Names}}' | grep -q "^server-setup-caddy$"; then
            $SUDO_CMD docker rm -f server-setup-caddy >/dev/null 2>&1 || true
        fi

        $SUDO_CMD docker run -d \
            --name server-setup-caddy \
            --restart unless-stopped \
            --network host \
            -v /etc/caddy/Caddyfile:/etc/caddy/Caddyfile:ro \
            -v caddy_data:/data \
            -v caddy_config:/config \
            caddy:alpine >/dev/null

        log_ok "Caddy ingress container running on ports 80/443 (memory: ~15 MB RAM)."
    else
        log_warn "Docker is not running; Caddyfile created at /etc/caddy/Caddyfile, container not started."
    fi
}

main() {
    local domain="localhost"
    local upstream="127.0.0.1:3000"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain) domain="$2"; shift 2 ;;
            --upstream) upstream="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    setup_caddy_ingress "$domain" "$upstream"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
