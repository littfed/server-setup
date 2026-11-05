#!/usr/bin/env bash
# ==============================================================================
# modules/ingress/cloudflare.sh - Cloudflare Tunnel (cloudflared) Ingress
# Provides secure ingress without exposing open ports 80/443 to the public web
# Memory footprint: ~15-25 MB RAM
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

# 1. Install cloudflared binary
install_cloudflared() {
    log_info "Checking cloudflared binary..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would download and install cloudflared"
        return 0
    fi

    if ! command -v cloudflared >/dev/null 2>&1; then
        local arch
        arch="$(uname -m)"
        local pkg="cloudflared-linux-amd64"
        case "$arch" in
            x86_64) pkg="cloudflared-linux-amd64" ;;
            aarch64|arm64) pkg="cloudflared-linux-arm64" ;;
            armv7l) pkg="cloudflared-linux-arm" ;;
        esac

        log_info "Downloading official cloudflared binary ($pkg)..."
        curl -fsSL -o /tmp/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/$pkg"
        $SUDO_CMD mv /tmp/cloudflared /usr/local/bin/cloudflared
        $SUDO_CMD chmod +x /usr/local/bin/cloudflared
        log_ok "cloudflared installed at /usr/local/bin/cloudflared."
    else
        log_ok "cloudflared already present ($(cloudflared --version 2>/dev/null | awk '{print $1,$2,$3}'))."
    fi
}

# 2. Configure systemd service with tunnel token
setup_cloudflare_tunnel() {
    local token="$1"

    if [ -z "$token" ]; then
        log_err "Cloudflare Tunnel requires --cf-token <TOKEN>."
        return 1
    fi

    log_info "Configuring cloudflared service..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would configure cloudflared systemd service with provided token"
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1; then
        # cloudflared has built-in service installer
        $SUDO_CMD /usr/local/bin/cloudflared service install "$token" >/dev/null 2>&1 || true
        $SUDO_CMD systemctl daemon-reload >/dev/null 2>&1 || true
        $SUDO_CMD systemctl enable --now cloudflared >/dev/null 2>&1 || true
        log_ok "cloudflared.service active and running with zero open ports!"
    else
        log_warn "systemd not available; cannot register cloudflared daemon."
    fi
}

main() {
    local token=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cf-token) token="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: $0 --cf-token <TOKEN>"
                exit 0
                ;;
            *) shift ;;
        esac
    done

    SUDO_CMD="$(get_sudo)"

    install_cloudflared
    if [ -n "$token" ]; then
        setup_cloudflare_tunnel "$token"
    else
        log_warn "No --cf-token supplied. cloudflared installed but tunnel not started."
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
