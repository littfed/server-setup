#!/usr/bin/env bash
# ==============================================================================
# Dokploy Lightweight Agent Join Script
# Run this directly on any remote Linux VPS to:
# 1. Optimize kernel, ZRAM, swap and Docker for <= 1 GB RAM (footprint ~90-110 MB)
# 2. Fetch Dokploy's SSH public key via API and authorize it automatically
# 3. Self-register the server into Dokploy via REST/tRPC API (Zero manual clicks)
# 4. Finalize handshake so the server is immediately visible and ready in Dokploy UI
# ==============================================================================

set -e

DOKPLOY_URL=""
API_KEY=""
SERVER_NAME="$(hostname)"
SERVER_PORT=22
SERVER_USER="${SUDO_USER:-${USER:-$(id -un)}}"
SSH_KEY_ID=""

usage() {
    cat <<EOF
Usage: $0 --dokploy-url <URL> --api-key <KEY> [options]

Required:
  --dokploy-url   URL of your Dokploy instance (e.g. https://dokploy.example.com)
  --api-key       Dokploy API Key (generate under User Settings -> API Keys)

Options:
  --name          Server display name in Dokploy (default: current hostname)
  --port          SSH port for Dokploy to connect to (default: 22)
  --user          SSH user for Dokploy to connect as (default: current user)
  --ssh-key-id    Specific Dokploy SSH Key ID to use (default: first active key)
  -h, --help      Show this help message
EOF
    exit 1
}

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dokploy-url) DOKPLOY_URL="${2%/}"; shift 2 ;;
        --api-key) API_KEY="$2"; shift 2 ;;
        --name) SERVER_NAME="$2"; shift 2 ;;
        --port) SERVER_PORT="$2"; shift 2 ;;
        --user) SERVER_USER="$2"; shift 2 ;;
        --ssh-key-id) SSH_KEY_ID="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [ -z "$DOKPLOY_URL" ] || [ -z "$API_KEY" ]; then
    echo "❌ Error: --dokploy-url and --api-key are required."
    usage
fi

if [ "$EUID" -eq 0 ]; then
    SUDO_CMD=""
else
    if sudo -n true 2>/dev/null; then
        SUDO_CMD="sudo"
    else
        echo "❌ Error: Sudo privileges required."
        exit 1
    fi
fi

echo "=========================================================="
echo " Starting Dokploy Lightweight Self-Registration Agent"
echo " Target Dokploy: $DOKPLOY_URL"
echo " Node Name:      $SERVER_NAME"
echo "=========================================================="

# 0. Dependencies check
command -v curl >/dev/null 2>&1 || ($SUDO_CMD apt-get update -qq && $SUDO_CMD apt-get install -y -qq curl)
command -v jq >/dev/null 2>&1 || ($SUDO_CMD apt-get update -qq && $SUDO_CMD apt-get install -y -qq jq)

# 1. System & Memory Optimization (Low RAM <= 1 GB)
echo ">>> [1/5] Applying low-RAM optimizations (ZRAM, Swap, sysctl)..."

# 1GB SSD Fallback swap
if [ "$(swapon --show --noheadings | wc -l)" -eq 0 ]; then
    echo "Creating 1 GB emergency swapfile..."
    $SUDO_CMD fallocate -l 1G /swapfile || $SUDO_CMD dd if=/dev/zero of=/swapfile bs=1M count=1024
    $SUDO_CMD chmod 600 /swapfile
    $SUDO_CMD mkswap /swapfile
    $SUDO_CMD swapon --priority 10 /swapfile
    echo '/swapfile none swap sw,pri=10 0 0' | $SUDO_CMD tee -a /etc/fstab >/dev/null
fi

# ZRAM (LZ4)
if command -v apt-get >/dev/null 2>&1; then
    $SUDO_CMD apt-get install -y -qq systemd-zram-generator crun 2>/dev/null || true
    if [ -d /etc/systemd ]; then
        cat <<'EOF' | $SUDO_CMD tee /etc/systemd/zram-generator.conf >/dev/null
[zram0]
zram-size = min(ram, 1024)
compression-algorithm = lz4
swap-priority = 100
EOF
        $SUDO_CMD systemctl daemon-reload
        $SUDO_CMD systemctl start /dev/zram0 2>/dev/null || true
    fi
fi

# Kernel memory tuning
cat <<'EOF' | $SUDO_CMD tee /etc/sysctl.d/99-docker-low-ram.conf >/dev/null
vm.swappiness = 100
vm.page-cluster = 0
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.vfs_cache_pressure = 100
vm.overcommit_memory = 1
vm.min_free_kbytes = 32768
EOF
$SUDO_CMD sysctl --system >/dev/null 2>&1 || true

# Disable systemd-oomd
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-oomd; then
    $SUDO_CMD systemctl stop systemd-oomd || true
    $SUDO_CMD systemctl disable --now systemd-oomd || true
fi

# 2. Docker & Containerd setup
echo ">>> [2/5] Setting up Docker Engine & containerd..."
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | $SUDO_CMD sh
fi

# Containerd tuning
$SUDO_CMD mkdir -p /etc/containerd
if [ -f /etc/containerd/config.toml ]; then
    $SUDO_CMD sed -i 's/disabled_plugins = .*/disabled_plugins = ["cri"]/' /etc/containerd/config.toml 2>/dev/null || true
else
    cat <<'EOF' | $SUDO_CMD tee /etc/containerd/config.toml >/dev/null
version = 2
disabled_plugins = ["cri"]
EOF
fi

# Docker daemon low-RAM tuning
$SUDO_CMD mkdir -p /etc/docker
CRUN_BIN=$(command -v crun || true)
if [ -n "$CRUN_BIN" ]; then
    cat <<EOF | $SUDO_CMD tee /etc/docker/daemon.json >/dev/null
{
  "userland-proxy": false,
  "max-concurrent-downloads": 1,
  "max-concurrent-uploads": 1,
  "live-restore": true,
  "features": { "buildkit": false },
  "default-runtime": "crun",
  "runtimes": { "crun": { "path": "$CRUN_BIN" } },
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3", "compress": "true" },
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 65535, "Soft": 65535 },
    "nproc": { "Name": "nproc", "Hard": 4096, "Soft": 4096 }
  },
  "storage-driver": "overlay2"
}
EOF
else
    cat <<'EOF' | $SUDO_CMD tee /etc/docker/daemon.json >/dev/null
{
  "userland-proxy": false,
  "max-concurrent-downloads": 1,
  "max-concurrent-uploads": 1,
  "live-restore": true,
  "features": { "buildkit": false },
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3", "compress": "true" },
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 65535, "Soft": 65535 },
    "nproc": { "Name": "nproc", "Hard": 4096, "Soft": 4096 }
  },
  "storage-driver": "overlay2"
}
EOF
fi

# GOMEMLIMIT drop-in
$SUDO_CMD mkdir -p /etc/systemd/system/docker.service.d
cat <<'EOF' | $SUDO_CMD tee /etc/systemd/system/docker.service.d/low-ram.conf >/dev/null
[Service]
Environment="GOMEMLIMIT=128MiB"
ManagedOOMMemoryPressure=none
EOF

$SUDO_CMD systemctl daemon-reload
$SUDO_CMD systemctl restart containerd || true
$SUDO_CMD systemctl restart docker || true

# Dokploy directories & bridge network
$SUDO_CMD mkdir -p /etc/dokploy/traefik/dynamic/certificates \
    /etc/dokploy/logs /etc/dokploy/applications /etc/dokploy/compose /etc/dokploy/ssh \
    /etc/dokploy/monitoring /etc/dokploy/registry /etc/dokploy/vector /etc/dokploy/schedules \
    /etc/dokploy/volume-backups /etc/dokploy/volume-backup-lock /etc/dokploy/patch-repos
$SUDO_CMD chmod 700 /etc/dokploy/ssh
$SUDO_CMD chown -R "$SERVER_USER":"$SERVER_USER" /etc/dokploy 2>/dev/null || true

if ! $SUDO_CMD docker network inspect dokploy-network >/dev/null 2>&1; then
    $SUDO_CMD docker network create --driver bridge --attachable dokploy-network
fi

# 3. Fetch Dokploy SSH Key & Authorize
echo ">>> [3/5] Querying Dokploy SSH Keys via API..."

SSH_KEYS_RESP=$(curl -sSL -f -H "x-api-key: $API_KEY" "$DOKPLOY_URL/api/sshKey.all" || true)

if [ -z "$SSH_KEYS_RESP" ] || [ "$SSH_KEYS_RESP" = "[]" ] || [ "$SSH_KEYS_RESP" = "null" ]; then
    echo "❌ Error: No SSH keys found in Dokploy. Please add at least one SSH Key in Dokploy Settings -> SSH Keys first."
    exit 1
fi

if [ -z "$SSH_KEY_ID" ]; then
    SSH_KEY_ID=$(echo "$SSH_KEYS_RESP" | jq -r '.[0].sshKeyId // empty')
    PUBLIC_KEY=$(echo "$SSH_KEYS_RESP" | jq -r '.[0].publicKey // empty')
else
    PUBLIC_KEY=$(echo "$SSH_KEYS_RESP" | jq -r --arg id "$SSH_KEY_ID" '.[] | select(.sshKeyId == $id) | .publicKey // empty')
fi

if [ -z "$PUBLIC_KEY" ] || [ "$PUBLIC_KEY" = "null" ]; then
    echo "❌ Error: Could not retrieve a valid public key from Dokploy."
    exit 1
fi

echo "Authorizing Dokploy SSH Public Key for $SERVER_USER..."
TARGET_HOME=$(eval echo "~$SERVER_USER")
$SUDO_CMD mkdir -p "$TARGET_HOME/.ssh"
$SUDO_CMD chmod 700 "$TARGET_HOME/.ssh"

# Add public key if not already present
if ! $SUDO_CMD grep -Fxq "$PUBLIC_KEY" "$TARGET_HOME/.ssh/authorized_keys" 2>/dev/null; then
    echo "$PUBLIC_KEY" | $SUDO_CMD tee -a "$TARGET_HOME/.ssh/authorized_keys" >/dev/null
    $SUDO_CMD chmod 600 "$TARGET_HOME/.ssh/authorized_keys"
    $SUDO_CMD chown -R "$SERVER_USER:$SERVER_USER" "$TARGET_HOME/.ssh"
    echo "Dokploy SSH Key authorized successfully ✅"
else
    echo "Dokploy SSH Key already present in authorized_keys ✅"
fi

# Add user to docker group
if [ -n "$SUDO_CMD" ]; then
    $SUDO_CMD usermod -aG docker "$SERVER_USER" 2>/dev/null || true
fi

# 4. Detect IP and Register Server in Dokploy
echo ">>> [4/5] Self-registering into Dokploy..."
PUBLIC_IP=$(curl -4s --connect-timeout 5 https://ifconfig.io || curl -4s --connect-timeout 5 https://api.ipify.org || hostname -I | awk '{print $1}')

if [ -z "$PUBLIC_IP" ]; then
    echo "❌ Error: Could not detect server public IP."
    exit 1
fi

echo "Registering: Name='$SERVER_NAME', IP='$PUBLIC_IP', Port=$SERVER_PORT, User='$SERVER_USER'..."

CREATE_PAYLOAD=$(jq -n \
  --arg name "$SERVER_NAME" \
  --arg desc "Lightweight Low-RAM Node (Auto-registered)" \
  --arg ip "$PUBLIC_IP" \
  --argjson port "$SERVER_PORT" \
  --arg user "$SERVER_USER" \
  --arg keyId "$SSH_KEY_ID" \
  '{
    name: $name,
    description: $desc,
    ipAddress: $ip,
    port: $port,
    username: $user,
    sshKeyId: $keyId,
    serverType: "deploy",
    enableDockerCleanup: true
  }')

CREATE_RESP=$(curl -sSL -f -X POST \
  -H "Content-Type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d "$CREATE_PAYLOAD" \
  "$DOKPLOY_URL/api/server.create")

SERVER_ID=$(echo "$CREATE_RESP" | jq -r '.serverId // .id // empty')

if [ -z "$SERVER_ID" ]; then
    echo "❌ Failed to register server in Dokploy. Response was:"
    echo "$CREATE_RESP"
    exit 1
fi

echo "Server registered successfully in Dokploy with ID: $SERVER_ID ✅"

# 5. Set custom lightweight verification command & Complete Handshake
echo ">>> [5/5] Completing Dokploy server handshake..."

FAST_COMMAND="echo 'Node successfully connected and optimized as Lightweight Worker ✅'"

UPDATE_PAYLOAD=$(jq -n \
  --arg name "$SERVER_NAME" \
  --arg desc "Lightweight Low-RAM Node (Auto-registered)" \
  --arg id "$SERVER_ID" \
  --arg ip "$PUBLIC_IP" \
  --argjson port "$SERVER_PORT" \
  --arg user "$SERVER_USER" \
  --arg keyId "$SSH_KEY_ID" \
  --arg cmd "$FAST_COMMAND" \
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
  }')

curl -sSL -f -X POST \
  -H "Content-Type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d "$UPDATE_PAYLOAD" \
  "$DOKPLOY_URL/api/server.update" >/dev/null

# Trigger setup handshake (Dokploy tests SSH and runs command)
SETUP_RESP=$(curl -sSL -f -X POST \
  -H "Content-Type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d "{\"serverId\":\"$SERVER_ID\"}" \
  "$DOKPLOY_URL/api/server.setup" || true)

USED_RAM=$(free -m | awk '/Mem:/ {print $3}')
TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')

echo ""
echo "=========================================================="
echo " 🎉 CONGRATULATIONS! Server linked with Dokploy!"
echo "=========================================================="
echo " Server Name : $SERVER_NAME"
echo " Server ID   : $SERVER_ID"
echo " Host / Port : $PUBLIC_IP:$SERVER_PORT"
echo " Current RAM : ${USED_RAM} MB in use / ${TOTAL_RAM} MB total"
echo " Dokploy URL : $DOKPLOY_URL/dashboard/settings/servers"
echo ""
echo " You can now deploy any pre-built Docker image to this"
echo " server from the Dokploy UI using the 'Compose' section!"
echo "=========================================================="
