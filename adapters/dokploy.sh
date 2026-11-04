#!/usr/bin/env bash
# ==============================================================================
# adapters/dokploy.sh - Dokploy Auto-Enrollment & Reverse Registration Adapter
# Fetches SSH key, authorizes it, and registers the server in Dokploy via REST/tRPC
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

# Detect public IP with multiple fallbacks
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

# Run adapter
run_dokploy_adapter() {
    local panel_url=""
    local api_key=""
    local server_name="$(hostname)"
    local server_port=22
    local server_user="${SUDO_USER:-$USER}"
    local ssh_key_id=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --panel-url) panel_url="${2%/}"; shift 2 ;;
            --api-key) api_key="$2"; shift 2 ;;
            --name) server_name="$2"; shift 2 ;;
            --port) server_port="$2"; shift 2 ;;
            --user) server_user="$2"; shift 2 ;;
            --ssh-key-id) ssh_key_id="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [ -z "$panel_url" ] || [ -z "$api_key" ]; then
        log_err "Dokploy adapter requires --panel-url <URL> and --api-key <KEY>."
        return 1
    fi

    log_info "=== Starting Dokploy Auto-Enrollment ==="
    log_info "Target Dokploy URL: $panel_url"
    log_info "Node Identity:      $server_name ($server_user@port:$server_port)"

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would query Dokploy /api/sshKey.all, add public key, and call /api/server.create"
        return 0
    fi

    # 1. Fetch Dokploy SSH Key
    log_info "Querying Dokploy SSH Keys..."
    local ssh_keys_resp
    ssh_keys_resp="$(curl -sSL -f -H "x-api-key: $api_key" "$panel_url/api/sshKey.all" 2>/dev/null || \
                     curl -sSL -f -H "x-api-key: $api_key" "$panel_url/api/trpc/sshKey.all" 2>/dev/null || true)"

    if [ -z "$ssh_keys_resp" ] || [ "$ssh_keys_resp" = "[]" ] || [ "$ssh_keys_resp" = "null" ]; then
        log_err "Could not retrieve SSH keys from Dokploy. Please add an SSH Key in Dokploy Settings -> SSH Keys."
        return 1
    fi

    local public_key=""
    if [ -z "$ssh_key_id" ]; then
        ssh_key_id="$(echo "$ssh_keys_resp" | jq -r '.[0].sshKeyId // empty')"
        public_key="$(echo "$ssh_keys_resp" | jq -r '.[0].publicKey // empty')"
    else
        public_key="$(echo "$ssh_keys_resp" | jq -r --arg id "$ssh_key_id" '.[] | select(.sshKeyId == $id) | .publicKey // empty')"
    fi

    if [ -z "$public_key" ] || [ "$public_key" = "null" ]; then
        log_err "No valid public key found in Dokploy response."
        return 1
    fi

    # 2. Authorize Dokploy SSH Key in ~/.ssh/authorized_keys
    log_info "Authorizing Dokploy SSH Public Key for $server_user..."
    local target_home
    target_home="$(eval echo "~$server_user")"
    $SUDO_CMD mkdir -p "$target_home/.ssh"
    $SUDO_CMD chmod 700 "$target_home/.ssh"

    local auth_keys="$target_home/.ssh/authorized_keys"
    if ! $SUDO_CMD grep -Fxq "$public_key" "$auth_keys" 2>/dev/null; then
        echo "$public_key" | $SUDO_CMD tee -a "$auth_keys" >/dev/null
        $SUDO_CMD chmod 600 "$auth_keys"
        $SUDO_CMD chown -R "$server_user:$server_user" "$target_home/.ssh"
        log_ok "Dokploy SSH Key authorized successfully."
    else
        log_ok "Dokploy SSH Key already present in authorized_keys."
    fi

    # 3. Detect Public IP & Register Server in Dokploy
    local public_ip
    public_ip="$(detect_public_ip)"
    log_info "Registering node: Name='$server_name', IP='$public_ip', Port=$server_port, User='$server_user'..."

    local create_payload
    create_payload="$(jq -n \
      --arg name "$server_name" \
      --arg desc "Lightweight Node (server-setup agent)" \
      --arg ip "$public_ip" \
      --argjson port "$server_port" \
      --arg user "$server_user" \
      --arg keyId "$ssh_key_id" \
      '{
        name: $name,
        description: $desc,
        ipAddress: $ip,
        port: $port,
        username: $user,
        sshKeyId: $keyId,
        serverType: "deploy",
        enableDockerCleanup: true
      }')"

    local create_resp
    create_resp="$(curl -sSL -f -X POST \
      -H "Content-Type: application/json" \
      -H "x-api-key: $api_key" \
      -d "$create_payload" \
      "$panel_url/api/server.create" 2>/dev/null || true)"

    local server_id
    server_id="$(echo "$create_resp" | jq -r '.serverId // .id // empty')"

    if [ -z "$server_id" ]; then
        log_err "Failed to register server in Dokploy. API response: $create_resp"
        return 1
    fi
    log_ok "Server registered in Dokploy with ID: $server_id."

    # 4. Set lightweight setup command & Trigger handshake
    log_info "Finalizing Dokploy server handshake..."
    local fast_cmd="echo 'Node optimized and active via server-setup agent ✅'"
    local update_payload
    update_payload="$(jq -n \
      --arg name "$server_name" \
      --arg desc "Lightweight Node (server-setup agent)" \
      --arg id "$server_id" \
      --arg ip "$public_ip" \
      --argjson port "$server_port" \
      --arg user "$server_user" \
      --arg keyId "$ssh_key_id" \
      --arg cmd "$fast_cmd" \
      '{
        name: $name,
        description: $desc,
        serverId: $id,
        ipAddress: $ip,
        port: $port,
        username: $user,
        sshKeyId: $keyId,
        serverType: "deploy",
        enableDockerCleanup: true,
        command: $cmd
      }')"

    curl -sSL -f -X POST \
      -H "Content-Type: application/json" \
      -H "x-api-key: $api_key" \
      -d "$update_payload" \
      "$panel_url/api/server.update" >/dev/null 2>&1 || true

    curl -sSL -f -X POST \
      -H "Content-Type: application/json" \
      -H "x-api-key: $api_key" \
      -d "{\"serverId\":\"$server_id\"}" \
      "$panel_url/api/server.setup" >/dev/null 2>&1 || true

    log_ok "=== Dokploy Auto-Enrollment Completed Successfully! ==="
    log_ok "Dashboard URL: $panel_url/dashboard/settings/servers"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_dokploy_adapter "$@"
fi
