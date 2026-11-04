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
        log_ok "[dry-run] Would tune containerd configuration"
        return 0
    fi

    # Detect containerd major version
    local containerd_ver
    containerd_ver="$(containerd --version 2>/dev/null | awk '{print $3}' | cut -d. -f1 || echo '1')"

    local cfg="/etc/containerd/config.toml"
    $SUDO_CMD mkdir -p /etc/containerd

    if [ "$containerd_ver" = "v2" ] || [ "$containerd_ver" = "2" ]; then
        # containerd v2 uses full plugin URI
        if [ ! -f "$cfg" ]; then
            cat <<'EOF' | $SUDO_CMD tee "$cfg" >/dev/null
version = 3
disabled_plugins = ["io.containerd.cri.v1", "io.containerd.grpc.v1.cri"]
EOF
        fi
    else
        # containerd v1
        if [ ! -f "$cfg" ]; then
            cat <<'EOF' | $SUDO_CMD tee "$cfg" >/dev/null
version = 2
disabled_plugins = ["cri"]
EOF
        fi
    fi
    log_ok "containerd optimized."
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

    # Check if crun supports OCI spec >= 1.2.0 required by modern Docker (Docker 28+)
    local use_crun_as_default=0
    if [ -n "$crun_bin" ]; then
        local oci_max
        oci_max="$($crun_bin features 2>/dev/null | grep '"ociVersionMax"' | tr -dc '0-9.' | head -n 1 || echo '1.0')"
        local major minor
        major=$(echo "$oci_max" | cut -d. -f1)
        minor=$(echo "$oci_max" | cut -d. -f2)
        if [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 2 ]; }; then
            use_crun_as_default=1
        fi
    fi

    # Check if Docker is using containerd-snapshotter
    local use_snapshotter=0
    if docker info 2>/dev/null | grep -qi "containerd-snapshotter.*true"; then
        use_snapshotter=1
    fi

    local tmp_low_ram
    tmp_low_ram="$(mktemp)"

    if [ "$use_snapshotter" -eq 1 ]; then
        cat <<EOF > "$tmp_low_ram"
{
  "userland-proxy": false,
  "max-concurrent-downloads": 1,
  "max-concurrent-uploads": 1,
  "live-restore": true,
  "features": {
    "buildkit": false,
    "containerd-snapshotter": true
  },
  $([ "$use_crun_as_default" -eq 1 ] && echo '"default-runtime": "crun",')
  $([ -n "$crun_bin" ] && echo '"runtimes": { "crun": { "path": "'"$crun_bin"'" } },')
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3",
    "compress": "true"
  },
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 65535, "Soft": 65535 },
    "nproc": { "Name": "nproc", "Hard": 4096, "Soft": 4096 }
  }
}
EOF
    else
        cat <<EOF > "$tmp_low_ram"
{
  "userland-proxy": false,
  "max-concurrent-downloads": 1,
  "max-concurrent-uploads": 1,
  "live-restore": true,
  "features": {
    "buildkit": false
  },
  $([ "$use_crun_as_default" -eq 1 ] && echo '"default-runtime": "crun",')
  $([ -n "$crun_bin" ] && echo '"runtimes": { "crun": { "path": "'"$crun_bin"'" } },')
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

    local target_file="/etc/docker/daemon.json"
    if [ -f "$target_file" ] && [ -s "$target_file" ]; then
        log_info "Existing $target_file detected. Backing up and merging configurations safely..."
        local backup_file
        backup_file="${target_file}.bak.$(date +%Y%m%d%H%M%S)"
        $SUDO_CMD cp "$target_file" "$backup_file"
        log_ok "Backup created at $backup_file."

        # Perform deep merge preserving existing user keys
        if command -v jq >/dev/null 2>&1; then
            local merged_json
            merged_json=$(jq -s '.[0] * .[1]' "$target_file" "$tmp_low_ram" 2>/dev/null || true)
            if [ -n "$merged_json" ]; then
                echo "$merged_json" | $SUDO_CMD tee "$target_file" >/dev/null
                rm -f "$tmp_low_ram"
                log_ok "Merged low-RAM options into existing $target_file via jq."
                return 0
            fi
        elif command -v python3 >/dev/null 2>&1; then
            local merged_file
            merged_file="$(mktemp)"
            python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f1, open(sys.argv[2]) as f2:
        d1 = json.load(f1)
        d2 = json.load(f2)
    def deep_update(target, src):
        for k, v in src.items():
            if isinstance(v, dict) and k in target and isinstance(target[k], dict):
                deep_update(target[k], v)
            else:
                target[k] = v
        return target
    merged = deep_update(d1, d2)
    with open(sys.argv[3], 'w') as out:
        json.dump(merged, out, indent=2)
except Exception:
    sys.exit(1)
" "$target_file" "$tmp_low_ram" "$merged_file" 2>/dev/null || true
            if [ -s "$merged_file" ]; then
                $SUDO_CMD cp "$merged_file" "$target_file"
                rm -f "$tmp_low_ram" "$merged_file"
                log_ok "Merged low-RAM options into existing $target_file via python3."
                return 0
            fi
            rm -f "$merged_file"
        fi
    fi

    $SUDO_CMD cp "$tmp_low_ram" "$target_file"
    rm -f "$tmp_low_ram"
    log_ok "$target_file configured successfully."
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
