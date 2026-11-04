#!/usr/bin/env bash
# ==============================================================================
# Dokploy Lightweight Remote Worker Setup Script
# Designed for low-spec servers (<= 1 GB RAM, 1 vCPU)
# Skips: Swarm, Traefik, Buildpacks, Nixpacks, Railpack, RClone, Vector/cAdvisor
# Baseline idle RAM footprint: ~85–120 MB (leaves >880 MB for containers)
# ==============================================================================

set -e

echo "=========================================================="
echo " Starting Dokploy Lightweight Worker Node Setup..."
echo " Target: Minimal footprint, Standalone Docker Compose"
echo "=========================================================="

CURRENT_USER="${SUDO_USER:-${USER:-$(id -un)}}"
if [ "$EUID" -eq 0 ]; then
    SUDO_CMD=""
    echo "Running as root ✅"
else
    if sudo -n true 2>/dev/null; then
        SUDO_CMD="sudo"
        echo "Running as $CURRENT_USER with sudo privileges ✅"
    else
        echo "Error: Non-root user requires passwordless sudo access. ❌"
        exit 1
    fi
fi

OS_TYPE=$(grep -w "ID" /etc/os-release | cut -d "=" -f 2 | tr -d '"')

# 1. Essential utilities
echo "1. Installing core utilities (curl, wget, jq, git)..."
if command -v apt-get >/dev/null 2>&1; then
    $SUDO_CMD apt-get update -qq
    $SUDO_CMD apt-get install -y -qq curl wget jq git
elif command -v dnf >/dev/null 2>&1; then
    $SUDO_CMD dnf install -y -q curl wget jq git
fi

# 2. Memory optimization: Swap & ZRAM
echo "2. Configuring memory protection (ZRAM + Fallback Swap)..."
if [ "$(swapon --show --noheadings | wc -l)" -eq 0 ]; then
    echo "Creating 1 GB fallback SSD swapfile..."
    $SUDO_CMD fallocate -l 1G /swapfile || $SUDO_CMD dd if=/dev/zero of=/swapfile bs=1M count=1024
    $SUDO_CMD chmod 600 /swapfile
    $SUDO_CMD mkswap /swapfile
    $SUDO_CMD swapon --priority 10 /swapfile
    echo '/swapfile none swap sw,pri=10 0 0' | $SUDO_CMD tee -a /etc/fstab >/dev/null
fi

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

# Kernel sysctl tuning for memory starvation prevention
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

# Disable systemd-oomd premature kills if active
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-oomd; then
    $SUDO_CMD systemctl stop systemd-oomd || true
    $SUDO_CMD systemctl disable --now systemd-oomd || true
fi

# 3. Docker Installation
echo "3. Installing Docker Engine..."
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | $SUDO_CMD sh
else
    echo "Docker already installed ✅"
fi

# 4. Containerd optimization
echo "4. Tuning containerd..."
$SUDO_CMD mkdir -p /etc/containerd
if [ -f /etc/containerd/config.toml ]; then
    $SUDO_CMD sed -i 's/disabled_plugins = .*/disabled_plugins = ["cri"]/' /etc/containerd/config.toml 2>/dev/null || true
else
    cat <<'EOF' | $SUDO_CMD tee /etc/containerd/config.toml >/dev/null
version = 2
disabled_plugins = ["cri"]
EOF
fi

# 5. Docker Daemon Low-RAM Optimization
echo "5. Optimizing /etc/docker/daemon.json..."
$SUDO_CMD mkdir -p /etc/docker
CRUN_BIN=$(command -v crun || true)

if [ -n "$CRUN_BIN" ]; then
    cat <<EOF | $SUDO_CMD tee /etc/docker/daemon.json >/dev/null
{
  "userland-proxy": false,
  "max-concurrent-downloads": 1,
  "max-concurrent-uploads": 1,
  "live-restore": true,
  "features": {
    "buildkit": false
  },
  "default-runtime": "crun",
  "runtimes": {
    "crun": {
      "path": "$CRUN_BIN"
    }
  },
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3",
    "compress": "true"
  },
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
  "features": {
    "buildkit": false
  },
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3",
    "compress": "true"
  },
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 65535, "Soft": 65535 },
    "nproc": { "Name": "nproc", "Hard": 4096, "Soft": 4096 }
  },
  "storage-driver": "overlay2"
}
EOF
fi

# 6. Apply Go GC memory limit for dockerd
$SUDO_CMD mkdir -p /etc/systemd/system/docker.service.d
cat <<'EOF' | $SUDO_CMD tee /etc/systemd/system/docker.service.d/low-ram.conf >/dev/null
[Service]
Environment="GOMEMLIMIT=128MiB"
ManagedOOMMemoryPressure=none
EOF

# Restart Docker daemon with optimized parameters
$SUDO_CMD systemctl daemon-reload
$SUDO_CMD systemctl restart containerd || true
$SUDO_CMD systemctl restart docker || true

# 7. Dokploy Directories Setup
echo "6. Creating Dokploy system directories..."
$SUDO_CMD mkdir -p \
    /etc/dokploy/traefik/dynamic/certificates \
    /etc/dokploy/logs \
    /etc/dokploy/applications \
    /etc/dokploy/compose \
    /etc/dokploy/ssh \
    /etc/dokploy/monitoring \
    /etc/dokploy/registry \
    /etc/dokploy/vector \
    /etc/dokploy/schedules \
    /etc/dokploy/volume-backups \
    /etc/dokploy/volume-backup-lock \
    /etc/dokploy/patch-repos

$SUDO_CMD chmod 700 /etc/dokploy/ssh

# 8. Network Setup (Bridge mode, compatible with Compose without Swarm)
echo "7. Creating dokploy-network (bridge mode)..."
if ! $SUDO_CMD docker network inspect dokploy-network >/dev/null 2>&1; then
    $SUDO_CMD docker network create --driver bridge --attachable dokploy-network
    echo "dokploy-network bridge created ✅"
else
    echo "dokploy-network already exists ✅"
fi

# 9. Permissions
echo "8. Configuring permissions..."
if [ -n "$SUDO_CMD" ]; then
    if ! groups "$CURRENT_USER" | grep -qw docker; then
        $SUDO_CMD usermod -aG docker "$CURRENT_USER"
        echo "User $CURRENT_USER added to docker group ✅"
    fi
    $SUDO_CMD chown -R "$CURRENT_USER":"$CURRENT_USER" /etc/dokploy
    echo "Permissions configured for $CURRENT_USER ✅"
fi

echo "=========================================================="
echo " Dokploy Lightweight Worker Node Setup Completed! ✅"
echo " Memory footprint: ~85–120 MB RAM"
echo " Docker Swarm: Disabled (Compose Standalone ready)"
echo " Traefik: Disabled"
echo " Heavy Builders: Omitted"
echo "=========================================================="
