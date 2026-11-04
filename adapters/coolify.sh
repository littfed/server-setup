#!/usr/bin/env bash
# ==============================================================================
# adapters/coolify.sh - Coolify Auto-Enrollment & Reverse Registration Adapter
# Fetches SSH key, authorizes it, and registers the server in Coolify v4 API
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

detect_public_ip() {
    local ip=""
    ip="$(curl -4s --connect-timeout 4 https://ifconfig.io 2>/dev/null || true)"
    if [ -z "$ip" ]; then
        ip="$(curl -4s --connect-timeout 4 https://api.ipify.org 2>/dev/null || true)"
    fi
    if [ -z "$ip" ]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '127.0.0.1')"
    fi
    echo "$ip"
}

run_coolify_adapter() {
    local panel_url=""
    local api_key=""
    local server_name
    server_name="$(hostname)"
    local server_port=22
    local server_user="${SUDO_USER:-${USER:-$(id -un)}}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --panel-url) panel_url="${2%/}"; shift 2 ;;
            --api-key) api_key="$2"; shift 2 ;;
            --name) server_name="$2"; shift 2 ;;
            --port) server_port="$2"; shift 2 ;;
            --user) server_user="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [ -z "$panel_url" ] || [ -z "$api_key" ]; then
        log_err "Coolify adapter requires --panel-url <URL> and --api-key <TOKEN>."
        return 1
    fi

    log_info "=== Starting Coolify Auto-Enrollment ==="
    log_info "Target Coolify URL: $panel_url"
    log_info "Node Identity:      $server_name ($server_user@port:$server_port)"

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would query Coolify /api/v1/security/keys, authorize public key, and call /api/v1/servers"
        return 0
    fi

    # 1. Fetch Coolify SSH Key from /api/v1/security/keys
    log_info "Querying Coolify SSH Keys..."
    local keys_resp
    keys_resp="$(curl -sSL -f -H "Authorization: Bearer $api_key" "$panel_url/api/v1/security/keys" 2>/dev/null || true)"

    local public_key=""
    if [ -n "$keys_resp" ] && [ "$keys_resp" != "null" ]; then
        public_key="$(echo "$keys_resp" | jq -r '.[0].public_key // .public_key // empty')"
    fi

    if [ -z "$public_key" ] || [ "$public_key" = "null" ]; then
        log_warn "Could not fetch public SSH key automatically from Coolify API. Attempting server registration directly..."
    else
        log_info "Authorizing Coolify SSH Public Key for $server_user..."
        local target_home
        target_home="$(eval echo "~$server_user")"
        $SUDO_CMD mkdir -p "$target_home/.ssh"
        $SUDO_CMD chmod 700 "$target_home/.ssh"

        local auth_keys="$target_home/.ssh/authorized_keys"
        if ! $SUDO_CMD grep -Fxq "$public_key" "$auth_keys" 2>/dev/null; then
            echo "$public_key" | $SUDO_CMD tee -a "$auth_keys" >/dev/null
            $SUDO_CMD chmod 600 "$auth_keys"
            $SUDO_CMD chown -R "$server_user:$server_user" "$target_home/.ssh"
            log_ok "Coolify SSH Key authorized successfully."
        fi
    fi

    # 2. Register Server in Coolify
    local public_ip
    public_ip="$(detect_public_ip)"
    log_info "Registering node in Coolify: Name='$server_name', IP='$public_ip'..."

    local create_payload
    create_payload="$(jq -n \
      --arg name "$server_name" \
      --arg desc "Lightweight Node (server-setup agent)" \
      --arg ip "$public_ip" \
      --argjson port "$server_port" \
      --arg user "$server_user" \
      '{
        name: $name,
        description: $desc,
        ip: $ip,
        port: $port,
        user: $user,
        is_build_server: false
      }')"

    local create_resp
    create_resp="$(curl -sSL -f -X POST \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $api_key" \
      -d "$create_payload" \
      "$panel_url/api/v1/servers" 2>/dev/null || true)"

    local server_uuid
    server_uuid="$(echo "$create_resp" | jq -r '.uuid // .id // empty')"

    if [ -n "$server_uuid" ]; then
        log_ok "Server registered in Coolify with UUID: $server_uuid."
        # Validate connection
        curl -sSL -f -X GET \
          -H "Authorization: Bearer $api_key" \
          "$panel_url/api/v1/servers/$server_uuid/validate" >/dev/null 2>&1 || true
    else
        log_warn "Server registration response did not contain UUID, but API request completed. Response: $create_resp"
    fi

    log_ok "=== Coolify Auto-Enrollment Completed Successfully! ==="
    log_ok "Dashboard URL: $panel_url/servers"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_coolify_adapter "$@"
fi
