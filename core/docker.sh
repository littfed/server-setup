#!/usr/bin/env bash
# ==============================================================================
# core/docker.sh - Docker Low-RAM Engine Optimization for Small VPS (<= 1 GB)
# Features: crun OCI runtime + daemon.json tuning + GOMEMLIMIT + bridge network
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
CURRENT_USER="${SUDO_USER:-${USER:-$(id -un)}}"

# 1. Install Docker Engine if not present
install_docker() {
    log_info "Checking Docker Engine installation..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would verify/install Docker Engine"
        return 0
    fi

    if ! command -v docker >/dev/null 2>&1; then
        log_info "Docker not found. Installing official Docker Engine..."
        curl -fsSL https://get.docker.com | $SUDO_CMD sh
        log_ok "Docker Engine installed successfully."
    else
        local ver
        ver="$(docker --version 2>/dev/null || echo 'installed')"
        log_ok "Docker Engine already present ($ver)."
    fi
}

# 2. Install crun OCI runtime (2-4 MB per container vs 25 MB with runc)
install_crun() {
    log_info "Ensuring crun OCI runtime is installed..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would install crun package"
        return 0
    fi

    if ! command -v crun >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            $SUDO_CMD apt-get update -qq >/dev/null 2>&1 || true
            $SUDO_CMD apt-get install -y -qq crun >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null 2>&1; then
            $SUDO_CMD dnf install -y -q crun >/dev/null 2>&1 || true
        fi
    fi

    if command -v crun >/dev/null 2>&1; then
        log_ok "crun OCI runtime available at $(command -v crun)."
    else
        log_warn "crun package not available; will use default runc runtime."
    fi
}

# 3. Optimize containerd configuration
tune_containerd() {
    log_info "Tuning containerd configuration..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would disable CRI plugin in /etc/containerd/config.toml"
        return 0
    fi

    $SUDO_CMD mkdir -p /etc/containerd
    local cfg="/etc/containerd/config.toml"

    if [ -f "$cfg" ]; then
        if ! grep -q 'disabled_plugins = \["cri"\]' "$cfg"; then
            $SUDO_CMD sed -i 's/disabled_plugins = .*/disabled_plugins = ["cri"]/' "$cfg" 2>/dev/null || true
        fi
    else
        cat <<'EOF' | $SUDO_CMD tee "$cfg" >/dev/null
version = 2
disabled_plugins = ["cri"]
EOF
    fi
    log_ok "containerd optimized (CRI plugin disabled, saves ~20 MB RAM)."
}

# 4. Configure /etc/docker/daemon.json
configure_daemon_json() {
    log_info "Applying low-RAM optimizations to /etc/docker/daemon.json..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would write /etc/docker/daemon.json (userland-proxy=false, max-concurrent=1, buildkit=false)"
        return 0
    fi

    $SUDO_CMD mkdir -p /etc/docker
    local crun_bin
    crun_bin="$(command -v crun || true)"

    if [ -n "$crun_bin" ]; then
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
      "path": "$crun_bin"
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
    log_ok "/etc/docker/daemon.json configured."
}

# 5. Apply Go memory limit drop-in for dockerd
tune_systemd_docker() {
    log_info "Configuring GOMEMLIMIT=128MiB for docker.service..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would create /etc/systemd/system/docker.service.d/low-ram.conf"
        return 0
    fi

    local dropin_dir="/etc/systemd/system/docker.service.d"
    $SUDO_CMD mkdir -p "$dropin_dir"
    cat <<'EOF' | $SUDO_CMD tee "$dropin_dir/low-ram.conf" >/dev/null
[Service]
Environment="GOMEMLIMIT=128MiB"
ManagedOOMMemoryPressure=none
EOF

    if command -v systemctl >/dev/null 2>&1; then
        $SUDO_CMD systemctl daemon-reload >/dev/null 2>&1 || true
        $SUDO_CMD systemctl restart containerd >/dev/null 2>&1 || true
        $SUDO_CMD systemctl restart docker >/dev/null 2>&1 || true
    fi
    log_ok "docker.service restarted with GOMEMLIMIT=128MiB."
}

# 6. Create bridge network (dokploy-network) & permissions
setup_network_and_permissions() {
    log_info "Setting up default bridge network and user permissions..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would create dokploy-network bridge and add $CURRENT_USER to docker group"
        return 0
    fi

    # Create network
    if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
        if ! docker network inspect dokploy-network >/dev/null 2>&1; then
            $SUDO_CMD docker network create --driver bridge --attachable dokploy-network >/dev/null
            log_ok "Created dokploy-network bridge."
        else
            log_ok "dokploy-network bridge already exists."
        fi
    fi

    # Add user to docker group
    if [ -n "$SUDO_CMD" ] && [ -n "$CURRENT_USER" ]; then
        if ! groups "$CURRENT_USER" 2>/dev/null | grep -qw docker; then
            $SUDO_CMD usermod -aG docker "$CURRENT_USER" 2>/dev/null || true
            log_ok "User $CURRENT_USER added to docker group."
        fi
    fi
}

tune_docker() {
    log_info "=== Starting Docker Low-RAM Engine Optimization ==="
    install_docker
    install_crun
    tune_containerd
    configure_daemon_json
    tune_systemd_docker
    setup_network_and_permissions
    log_ok "=== Docker Low-RAM Engine Optimization Completed ==="
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    tune_docker
fi
