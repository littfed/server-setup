#!/usr/bin/env bash
# ==============================================================================
# modules/security/ids.sh - Adaptive Intrusion Detection & Prevention (Fail2ban / CrowdSec)
# Features: RAM-aware engine selection (<=1.5GB -> Fail2ban, >1.5GB -> CrowdSec)
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
  --mode <type>          IDS engine: auto | fail2ban | crowdsec (default: auto)
  --ids <type>           Alias for --mode
  --dry-run              Simulate execution without modifying system
  -h, --help             Show this help message
EOF
    exit 0
}

MODE="auto"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode|--ids)
            MODE="$2"
            shift 2
            ;;
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

detect_target_engine() {
    if [ "$MODE" != "auto" ]; then
        echo "$MODE"
        return
    fi

    # If Fail2ban is already active, keep using Fail2ban
    if command -v fail2ban-client >/dev/null 2>&1; then
        echo "fail2ban"
        return
    fi

    # If CrowdSec is already active, keep using CrowdSec
    if command -v cscli >/dev/null 2>&1; then
        echo "crowdsec"
        return
    fi

    # Read RAM in MB from /proc/meminfo or free
    local total_kb=0
    if [ -f /proc/meminfo ]; then
        total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    fi

    local total_mb=$(( total_kb / 1024 ))

    # <= 1536 MB (1.5 GB): Fail2ban (~25 MB RAM overhead)
    # > 1536 MB: CrowdSec (~100-150 MB RAM overhead, collaborative threat intel)
    if [ "$total_mb" -gt 0 ] && [ "$total_mb" -le 1536 ]; then
        echo "fail2ban"
    else
        echo "crowdsec"
    fi
}

setup_fail2ban() {
    log_info "Configuring lightweight Fail2ban intrusion prevention..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would install fail2ban package"
        log_ok "[dry-run] Would write /etc/fail2ban/jail.d/ssh-hardened.local"
        log_ok "[dry-run] Would enable and start fail2ban service"
        return 0
    fi

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive $SUDO_CMD apt-get update -qq >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive $SUDO_CMD apt-get install -y -qq fail2ban >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null 2>&1; then
            $SUDO_CMD dnf install -y epel-release >/dev/null 2>&1 || true
            $SUDO_CMD dnf install -y fail2ban >/dev/null 2>&1 || true
        fi
        log_ok "Fail2ban package installed."
    fi

    $SUDO_CMD mkdir -p /etc/fail2ban/jail.d
    cat <<'EOF' | $SUDO_CMD tee /etc/fail2ban/jail.d/ssh-hardened.local >/dev/null
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ssh
filter = sshd
EOF

    if command -v systemctl >/dev/null 2>&1; then
        $SUDO_CMD systemctl enable --now fail2ban >/dev/null 2>&1 || true
        $SUDO_CMD systemctl restart fail2ban >/dev/null 2>&1 || true
    fi
    log_ok "Fail2ban is active with ssh-hardened jail (bantime=1h, maxretry=5)."
}

setup_crowdsec() {
    log_info "Configuring CrowdSec collaborative intrusion prevention & bouncer..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would install crowdsec and firewall bouncer"
        log_ok "[dry-run] Would enable and start crowdsec services"
        return 0
    fi

    if ! command -v cscli >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            curl -s https://packagecloud.io/install/repositories/crowdsecurity/crowdsec/script.deb.sh | $SUDO_CMD bash >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive $SUDO_CMD apt-get update -qq >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive $SUDO_CMD apt-get install -y -qq crowdsec crowdsec-firewall-bouncer-iptables >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null 2>&1; then
            curl -s https://packagecloud.io/install/repositories/crowdsecurity/crowdsec/script.rpm.sh | $SUDO_CMD bash >/dev/null 2>&1 || true
            $SUDO_CMD dnf install -y crowdsec crowdsec-firewall-bouncer-iptables >/dev/null 2>&1 || true
        fi
        log_ok "CrowdSec packages installed."
    fi

    # Install Linux & SSH collections if cscli is available
    if command -v cscli >/dev/null 2>&1; then
        $SUDO_CMD cscli collections install crowdsecurity/linux >/dev/null 2>&1 || true
        $SUDO_CMD cscli collections install crowdsecurity/sshd >/dev/null 2>&1 || true
    fi

    if command -v systemctl >/dev/null 2>&1; then
        $SUDO_CMD systemctl enable --now crowdsec >/dev/null 2>&1 || true
        $SUDO_CMD systemctl enable --now crowdsec-firewall-bouncer >/dev/null 2>&1 || true
    fi
    log_ok "CrowdSec and firewall bouncer are active with community threat intelligence."
}

main() {
    log_info "=== Starting Adaptive Intrusion Prevention Setup ==="
    local engine
    engine="$(detect_target_engine)"
    log_info "Selected IDS engine: $engine (mode: $MODE)"

    case "$engine" in
        fail2ban)
            setup_fail2ban
            ;;
        crowdsec)
            setup_crowdsec
            ;;
        *)
            log_err "Unknown IDS engine: $engine"
            exit 1
            ;;
    esac
    log_ok "=== Intrusion Prevention Setup Completed ==="
}

main "$@"
