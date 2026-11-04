#!/usr/bin/env bash
# ==============================================================================
# core/memory.sh - Linux Memory Optimization for Low-RAM VPS (<= 1 GB RAM)
# Features: ZRAM (LZ4) + SSD fallback swapfile + sysctl kernel memory tuning
# ==============================================================================

set -euo pipefail

# Helper logging
log_info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
log_ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
log_err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

# Detect sudo
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

# 1. Fallback SSD Swapfile (1 GB)
setup_swapfile() {
    local swap_size="${1:-1G}"
    local swapfile="/swapfile"

    log_info "Checking system swap..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would ensure 1GB swapfile exists at $swapfile"
        return 0
    fi

    # Only create fallback swap if no active swap exists
    if [ "$(swapon --show --noheadings 2>/dev/null | wc -l)" -eq 0 ]; then
        log_info "No active swap detected. Creating $swap_size emergency swapfile at $swapfile..."
        if ! $SUDO_CMD fallocate -l "$swap_size" "$swapfile" 2>/dev/null; then
            $SUDO_CMD dd if=/dev/zero of="$swapfile" bs=1M count=1024 status=progress
        fi
        $SUDO_CMD chmod 600 "$swapfile"
        $SUDO_CMD mkswap "$swapfile" >/dev/null
        $SUDO_CMD swapon --priority 10 "$swapfile"

        # Idempotent /etc/fstab entry
        if ! grep -qs "^$swapfile " /etc/fstab; then
            echo "$swapfile none swap sw,pri=10 0 0" | $SUDO_CMD tee -a /etc/fstab >/dev/null
        fi
        log_ok "Emergency swapfile created and activated with priority 10."
    else
        log_ok "Existing swap detected ($(swapon --show --noheadings | wc -l) devices). Skipping swapfile creation."
    fi
}

# 2. ZRAM configuration (LZ4 compression, priority 100)
setup_zram() {
    log_info "Configuring ZRAM in-memory compressed swap (LZ4)..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would install systemd-zram-generator and configure [zram0]"
        return 0
    fi

    # Check if zram is already active
    if swapon --show 2>/dev/null | grep -q "zram"; then
        log_ok "ZRAM device already active in system."
        return 0
    fi

    if command -v apt-get >/dev/null 2>&1; then
        $SUDO_CMD apt-get update -qq >/dev/null 2>&1 || true
        $SUDO_CMD apt-get install -y -qq systemd-zram-generator >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        $SUDO_CMD dnf install -y -q zram-generator >/dev/null 2>&1 || true
    fi

    if [ -d /etc/systemd ]; then
        cat <<'EOF' | $SUDO_CMD tee /etc/systemd/zram-generator.conf >/dev/null
[zram0]
zram-size = min(ram, 1024)
compression-algorithm = lz4
swap-priority = 100
EOF
        $SUDO_CMD systemctl daemon-reload >/dev/null 2>&1 || true
        $SUDO_CMD systemctl start /dev/zram0 >/dev/null 2>&1 || true
        log_ok "ZRAM configured with priority 100."
    else
        log_warn "systemd not detected; skipping zram-generator configuration."
    fi
}

# 3. Kernel Sysctl Memory Tuning
setup_sysctl() {
    log_info "Applying kernel sysctl memory parameters..."
    local conf_file="/etc/sysctl.d/99-docker-low-ram.conf"

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would apply sysctl: vm.swappiness=100, page-cluster=0, min_free_kbytes=32768"
        return 0
    fi

    cat <<'EOF' | $SUDO_CMD tee "$conf_file" >/dev/null
# Prefer in-memory ZRAM swap over dropping filesystem caches
vm.swappiness = 100
# Single page readahead optimal for compressed RAM swap
vm.page-cluster = 0
# Flushes dirty memory early to prevent buffer lockups
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
# Cache reclaiming pressure
vm.vfs_cache_pressure = 100
# Safe memory overcommit
vm.overcommit_memory = 1
# Emergency free kernel headroom to avoid allocation deadlocks
vm.min_free_kbytes = 32768
EOF

    if command -v sysctl >/dev/null 2>&1; then
        $SUDO_CMD sysctl --system >/dev/null 2>&1 || true
    fi
    log_ok "Kernel sysctl tuning applied successfully."
}

# 4. Disable systemd-oomd premature kills
disable_systemd_oomd() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would stop and disable systemd-oomd"
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-oomd 2>/dev/null; then
        log_info "Disabling systemd-oomd to prevent early cgroup kills..."
        $SUDO_CMD systemctl stop systemd-oomd >/dev/null 2>&1 || true
        $SUDO_CMD systemctl disable --now systemd-oomd >/dev/null 2>&1 || true
        log_ok "systemd-oomd disabled."
    fi
}

# 5. Cap journald disk and memory usage
tune_journald() {
    log_info "Tuning journald log limits (capping at 100MB)..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would configure journald SystemMaxUse=100M"
        return 0
    fi

    if [ -d /etc/systemd ]; then
        $SUDO_CMD mkdir -p /etc/systemd/journald.conf.d
        cat <<'EOF' | $SUDO_CMD tee /etc/systemd/journald.conf.d/low-ram.conf >/dev/null
[Journal]
SystemMaxUse=100M
RuntimeMaxUse=50M
EOF
        $SUDO_CMD systemctl restart systemd-journald >/dev/null 2>&1 || true
        if command -v journalctl >/dev/null 2>&1; then
            $SUDO_CMD journalctl --vacuum-size=100M >/dev/null 2>&1 || true
        fi
        log_ok "journald limits configured and old logs vacuumed."
    fi
}

# Main function
tune_memory() {
    log_info "=== Starting Linux Memory Optimization ==="
    setup_swapfile "1G"
    setup_zram
    setup_sysctl
    disable_systemd_oomd
    tune_journald
    log_ok "=== Memory Optimization Completed Successfully ==="
}

# Execute if run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    tune_memory
fi
