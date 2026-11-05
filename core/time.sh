#!/usr/bin/env bash
# ==============================================================================
# core/time.sh - Accurate System Clock Synchronization (NTP / timesyncd / chrony)
# Prevents clock drift issues with SSL certs, JWT validation, and 2FA auth
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

configure_time_sync() {
    log_info "Configuring accurate system time synchronization..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would configure NTP pool (time.cloudflare.com, time.google.com, pool.ntp.org)"
        log_ok "[dry-run] Would enable systemd-timesyncd or chrony"
        return 0
    fi

    local configured=0

    # 1. Preferred: systemd-timesyncd
    if command -v timedatectl >/dev/null 2>&1; then
        # Check if timesyncd exists or can be installed
        if ! systemctl list-unit-files 2>/dev/null | grep -q "systemd-timesyncd"; then
            if command -v apt-get >/dev/null 2>&1; then
                DEBIAN_FRONTEND=noninteractive $SUDO_CMD apt-get update -qq >/dev/null 2>&1 || true
                DEBIAN_FRONTEND=noninteractive $SUDO_CMD apt-get install -y -qq systemd-timesyncd >/dev/null 2>&1 || true
            fi
        fi

        if systemctl list-unit-files 2>/dev/null | grep -q "systemd-timesyncd"; then
            $SUDO_CMD mkdir -p /etc/systemd/timesyncd.conf.d
            cat <<'EOF' | $SUDO_CMD tee /etc/systemd/timesyncd.conf.d/99-ntp.conf >/dev/null
[Time]
NTP=time.cloudflare.com time.google.com pool.ntp.org
FallbackNTP=0.debian.pool.ntp.org 1.debian.pool.ntp.org
PollIntervalMinSec=32
PollIntervalMaxSec=2048
EOF
            $SUDO_CMD systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
            $SUDO_CMD systemctl restart systemd-timesyncd >/dev/null 2>&1 || true
            $SUDO_CMD timedatectl set-ntp true >/dev/null 2>&1 || true
            configured=1
            log_ok "systemd-timesyncd configured with Cloudflare & Google NTP servers."
        fi
    fi

    # 2. Fallback: chrony
    if [ "$configured" -eq 0 ]; then
        if ! command -v chronyd >/dev/null 2>&1; then
            if command -v dnf >/dev/null 2>&1; then
                $SUDO_CMD dnf install -y chrony >/dev/null 2>&1 || true
            elif command -v apk >/dev/null 2>&1; then
                $SUDO_CMD apk add chrony >/dev/null 2>&1 || true
            fi
        fi

        if command -v chronyd >/dev/null 2>&1; then
            if command -v systemctl >/dev/null 2>&1; then
                $SUDO_CMD systemctl enable --now chronyd || $SUDO_CMD systemctl enable --now chrony || true
            fi
            configured=1
            log_ok "chrony time synchronization enabled."
        fi
    fi

    if [ "$configured" -eq 0 ]; then
        log_warn "Neither systemd-timesyncd nor chrony could be configured. NTP status unverified."
    fi
}

main() {
    log_info "=== Starting Time Synchronization Setup ==="
    configure_time_sync
    log_ok "=== Time Synchronization Setup Completed ==="
}

main "$@"
