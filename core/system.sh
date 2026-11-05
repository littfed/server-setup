#!/usr/bin/env bash
# ==============================================================================
# core/system.sh - Baseline Linux System Tuning & Network Hardening
# Features: Google BBR, Sysctl Network Hardening, File Descriptors, fstrim, Updates
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

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --dry-run              Simulate execution without modifying the host
  -h, --help             Show this help message
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            export DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_err "Unknown option: $1"
            usage
            ;;
    esac
done

SUDO_CMD="$(get_sudo)"

# 1. Enable Google BBR TCP Congestion Control
tune_bbr() {
    log_info "Enabling Google BBR TCP Congestion Control..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would enable tcp_bbr kernel module and configure fq + bbr in /etc/sysctl.d/99-bbr.conf"
        return 0
    fi

    # Load kernel module
    $SUDO_CMD modprobe tcp_bbr 2>/dev/null || true
    $SUDO_CMD mkdir -p /etc/modules-load.d
    if ! grep -qs "tcp_bbr" /etc/modules-load.d/bbr.conf 2>/dev/null; then
        echo "tcp_bbr" | $SUDO_CMD tee /etc/modules-load.d/bbr.conf >/dev/null
    fi

    $SUDO_CMD mkdir -p /etc/sysctl.d
    cat <<'EOF' | $SUDO_CMD tee /etc/sysctl.d/99-bbr.conf >/dev/null
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    $SUDO_CMD sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    $SUDO_CMD sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
    log_ok "Google BBR congestion control configured."
}

# 2. Kernel Network Security & Anti-Spoofing Hardening
tune_kernel_network() {
    log_info "Configuring kernel network hardening (SYN cookies, rp_filter, ICMP)..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would write /etc/sysctl.d/99-network-security.conf and apply sysctl settings"
        return 0
    fi

    $SUDO_CMD mkdir -p /etc/sysctl.d
    cat <<'EOF' | $SUDO_CMD tee /etc/sysctl.d/99-network-security.conf >/dev/null
# TCP SYN Flood Protection
net.ipv4.tcp_syncookies = 1

# Disable ICMP redirect acceptance
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Disable ICMP redirect sending
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Enable IP spoofing protection (Reverse Path Filtering)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP broadcast echo requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignore bogus ICMP error responses
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Log spoofed, source routed, and redirect packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Buffer size improvements for high throughput
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF

    $SUDO_CMD sysctl -p /etc/sysctl.d/99-network-security.conf >/dev/null 2>&1 || true
    log_ok "Kernel network hardening applied."
}

# 3. System Limits & File Descriptors Tuning
tune_system_limits() {
    log_info "Tuning system limits and file descriptors..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would configure DefaultLimitNOFILE=65535:1048576 and fs.file-max=2097152"
        return 0
    fi

    # PAM limits
    $SUDO_CMD mkdir -p /etc/security/limits.d
    cat <<'EOF' | $SUDO_CMD tee /etc/security/limits.d/99-nofile.conf >/dev/null
* soft nofile 65535
* hard nofile 1048576
root soft nofile 65535
root hard nofile 1048576
EOF

    # Systemd manager limits
    $SUDO_CMD mkdir -p /etc/systemd/system.conf.d
    cat <<'EOF' | $SUDO_CMD tee /etc/systemd/system.conf.d/limits.conf >/dev/null
[Manager]
DefaultLimitNOFILE=65535:1048576
EOF

    # Kernel file-max
    $SUDO_CMD mkdir -p /etc/sysctl.d
    cat <<'EOF' | $SUDO_CMD tee /etc/sysctl.d/99-file-max.conf >/dev/null
fs.file-max = 2097152
EOF

    $SUDO_CMD sysctl -w fs.file-max=2097152 >/dev/null 2>&1 || true
    log_ok "System limits tuned (DefaultLimitNOFILE=65535:1048576, fs.file-max=2097152)."
}

# 4. Storage Optimization (SSD/NVMe fstrim)
tune_storage_trim() {
    log_info "Configuring weekly SSD/NVMe fstrim timer..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would enable fstrim.timer"
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1; then
        $SUDO_CMD systemctl enable --now fstrim.timer >/dev/null 2>&1 || true
        log_ok "fstrim.timer enabled."
    fi
}

# 5. Automated Security Updates
configure_unattended_upgrades() {
    log_info "Checking automatic security updates configuration..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would configure automatic security updates (unattended-upgrades)"
        return 0
    fi

    if command -v apt-get >/dev/null 2>&1; then
        if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive $SUDO_CMD apt-get update -qq >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive $SUDO_CMD apt-get install -y -qq unattended-upgrades >/dev/null 2>&1 || true
        fi

        $SUDO_CMD mkdir -p /etc/apt/apt.conf.d
        cat <<'EOF' | $SUDO_CMD tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
        if command -v systemctl >/dev/null 2>&1; then
            $SUDO_CMD systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
        fi
        log_ok "Automatic security updates enabled."
    elif command -v dnf >/dev/null 2>&1; then
        if ! rpm -q dnf-automatic >/dev/null 2>&1; then
            $SUDO_CMD dnf install -y dnf-automatic >/dev/null 2>&1 || true
        fi
        if command -v systemctl >/dev/null 2>&1; then
            $SUDO_CMD systemctl enable --now dnf-automatic.timer >/dev/null 2>&1 || true
        fi
        log_ok "dnf-automatic security updates enabled."
    else
        log_warn "Automatic package upgrade configuration not supported on this distribution."
    fi
}

main() {
    log_info "=== Starting Linux System Tuning & Network Hardening ==="
    tune_bbr
    tune_kernel_network
    tune_system_limits
    tune_storage_trim
    configure_unattended_upgrades
    log_ok "=== Linux System Tuning & Network Hardening Completed ==="
}

main "$@"
