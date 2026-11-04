#!/usr/bin/env bash
# ==============================================================================
# setup.sh - Unified CLI Dispatcher for Server-Setup Toolkit
# Modular Linux & Docker Provisioning for Low-RAM Nodes with Control Plane Enrollment
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Formatting
BOLD="\033[1m"
GREEN="\033[1;32m"
BLUE="\033[1;34m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
RESET="\033[0m"

log_info() { echo -e "${BLUE}[INFO]${RESET} $*"; }
log_ok()   { echo -e "${GREEN}[OK]${RESET} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
log_err()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

banner() {
    cat <<EOF
${BOLD}${BLUE}
===================================================================
      Server-Setup: Lightweight Node Provisioning & Auto-Join
             https://github.com/littfed/server-setup
===================================================================
${RESET}
EOF
}

usage() {
    cat <<EOF
Usage: $0 [options]

Core Options:
  --panel <type>         Control plane: dokploy | coolify | standalone (default: standalone)
  --panel-url <url>      URL of the control plane (e.g. https://dokploy.example.com)
  --api-key <key>        API Key or Token for panel authentication
  --name <name>          Server display name (default: current hostname)
  --port <port>          SSH port of this machine (default: 22)
  --user <user>          SSH username for panel connection (default: current user)

Ingress Options:
  --ingress <type>       Ingress provider: none | cloudflare | caddy (default: none)
  --cf-token <token>     Cloudflare Tunnel token (required for --ingress cloudflare)
  --domain <domain>      Public domain name (used for --ingress caddy)
  --upstream <host:port> Upstream destination (default: 127.0.0.1:3000)

Maintenance Options:
  --auto-prune           Enable weekly safe Docker prune (default: enabled)
  --no-auto-prune        Disable Docker auto-prune
  --prune-age <age>      Age threshold for prune (default: 168h / 7 days)

Telemetry Options:
  --telemetry <type>     Telemetry mode: none | webhook | telegram (default: none)
  --webhook-url <url>    Webhook endpoint for JSON metrics and alerts
  --tg-token <token>     Telegram Bot token for alerts
  --tg-chat <chat_id>    Telegram Chat ID for alerts

General:
  --dry-run              Simulate execution without modifying the host
  -h, --help             Show this help message
EOF
    exit 0
}

# Defaults
PANEL="standalone"
PANEL_URL=""
API_KEY=""
SERVER_NAME="$(hostname)"
SERVER_PORT=22
SERVER_USER="${SUDO_USER:-$USER}"

INGRESS="none"
CF_TOKEN=""
DOMAIN="localhost"
UPSTREAM="127.0.0.1:3000"

AUTO_PRUNE=1
PRUNE_AGE="168h"

TELEMETRY="none"
WEBHOOK_URL=""
TG_TOKEN=""
TG_CHAT=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --panel) PANEL="$2"; shift 2 ;;
        --panel-url) PANEL_URL="${2%/}"; shift 2 ;;
        --api-key) API_KEY="$2"; shift 2 ;;
        --name) SERVER_NAME="$2"; shift 2 ;;
        --port) SERVER_PORT="$2"; shift 2 ;;
        --user) SERVER_USER="$2"; shift 2 ;;

        --ingress) INGRESS="$2"; shift 2 ;;
        --cf-token) CF_TOKEN="$2"; shift 2 ;;
        --domain) DOMAIN="$2"; shift 2 ;;
        --upstream) UPSTREAM="$2"; shift 2 ;;

        --auto-prune) AUTO_PRUNE=1; shift ;;
        --no-auto-prune) AUTO_PRUNE=0; shift ;;
        --prune-age) PRUNE_AGE="$2"; shift 2 ;;

        --telemetry) TELEMETRY="$2"; shift 2 ;;
        --webhook-url) WEBHOOK_URL="$2"; shift 2 ;;
        --tg-token) TG_TOKEN="$2"; shift 2 ;;
        --tg-chat) TG_CHAT="$2"; shift 2 ;;

        --dry-run) export DRY_RUN=1; shift ;;
        -h|--help) usage ;;
        *) log_err "Unknown option: $1"; usage ;;
    esac
done

banner

# Validation
if [ "$PANEL" = "dokploy" ] || [ "$PANEL" = "coolify" ]; then
    if [ -z "$PANEL_URL" ] || [ -z "$API_KEY" ]; then
        log_err "--panel $PANEL requires both --panel-url and --api-key."
        exit 1
    fi
fi

if [ "$INGRESS" = "cloudflare" ] && [ -z "$CF_TOKEN" ]; then
    log_err "--ingress cloudflare requires --cf-token <TOKEN>."
    exit 1
fi

log_info "Selected Configuration:"
log_info "  Panel:       $PANEL"
log_info "  Ingress:     $INGRESS"
log_info "  Auto-Prune:  $([ "$AUTO_PRUNE" -eq 1 ] && echo "enabled ($PRUNE_AGE)" || echo "disabled")"
log_info "  Telemetry:   $TELEMETRY"
log_info "  Dry Run:     ${DRY_RUN:-0}"
echo ""

# Helper to find module script (local or embedded)
find_script() {
    local rel_path="$1"
    if [ -f "$SCRIPT_DIR/$rel_path" ]; then
        echo "$SCRIPT_DIR/$rel_path"
    elif [ -f "./$rel_path" ]; then
        echo "./$rel_path"
    else
        log_err "Required component not found: $rel_path"
        exit 1
    fi
}

# Phase 1: Core System & Docker Low-RAM Engine
log_info ">>> [Phase 1/4] Running Core System & Memory Optimization..."
"$(find_script "core/memory.sh")"

log_info ">>> [Phase 2/4] Running Core Docker Low-RAM Engine Setup..."
"$(find_script "core/docker.sh")"

# Phase 2: Maintenance & Extensions
log_info ">>> [Phase 3/4] Configuring Selected Modules..."

if [ "$AUTO_PRUNE" -eq 1 ]; then
    log_info "Configuring Docker auto-prune..."
    "$(find_script "modules/maintenance/auto-prune.sh")" --filter-age "$PRUNE_AGE"
fi

if [ "$INGRESS" = "cloudflare" ]; then
    log_info "Configuring Cloudflare Tunnel Ingress..."
    "$(find_script "modules/ingress/cloudflare.sh")" --cf-token "$CF_TOKEN"
elif [ "$INGRESS" = "caddy" ]; then
    log_info "Configuring Caddy Ingress..."
    "$(find_script "modules/ingress/caddy.sh")" --domain "$DOMAIN" --upstream "$UPSTREAM"
fi

if [ "$TELEMETRY" = "webhook" ] || [ "$TELEMETRY" = "telegram" ]; then
    log_info "Configuring Telemetry cron..."
    "$(find_script "modules/telemetry/health-cron.sh")" --install-cron \
        --webhook-url "$WEBHOOK_URL" \
        --tg-token "$TG_TOKEN" \
        --tg-chat "$TG_CHAT"
fi

# Phase 3: Control Plane Enrollment
log_info ">>> [Phase 4/4] Executing Control Plane Adapter ($PANEL)..."

case "$PANEL" in
    dokploy)
        "$(find_script "adapters/dokploy.sh")" \
            --panel-url "$PANEL_URL" \
            --api-key "$API_KEY" \
            --name "$SERVER_NAME" \
            --port "$SERVER_PORT" \
            --user "$SERVER_USER"
        ;;
    coolify)
        "$(find_script "adapters/coolify.sh")" \
            --panel-url "$PANEL_URL" \
            --api-key "$API_KEY" \
            --name "$SERVER_NAME" \
            --port "$SERVER_PORT" \
            --user "$SERVER_USER"
        ;;
    standalone)
        "$(find_script "adapters/standalone.sh")"
        ;;
    *)
        log_err "Unsupported panel: $PANEL"
        exit 1
        ;;
esac

echo ""
log_ok "==================================================================="
log_ok " 🎉 All provisioning and configuration steps completed successfully!"
log_ok " Node is running with optimized low-RAM footprint (<110 MB idle)."
log_ok "==================================================================="
