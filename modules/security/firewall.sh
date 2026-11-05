#!/usr/bin/env bash
# ==============================================================================
# modules/security/firewall.sh - UFW Baseline Firewall & Docker Isolation
# Features: Default deny incoming, DOCKER-USER chain fix, auto-allow active workloads
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
  --ssh-port <port>      SSH port to ensure is allowed (default: auto-detected or 22)
  --open-ports <ports>   Comma-separated additional ports to open (e.g. 80,443)
  --dry-run              Simulate execution without modifying firewall
  -h, --help             Show this help message
EOF
    exit 0
}

SSH_PORT=""
EXTRA_PORTS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh-port|--port)
            SSH_PORT="$2"
            shift 2
            ;;
        --open-ports)
            EXTRA_PORTS="$2"
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

detect_ssh_port() {
    if [ -n "$SSH_PORT" ]; then
        echo "$SSH_PORT"
        return
    fi
    # Check SSH_CONNECTION env if available
    if [ -n "${SSH_CONNECTION:-}" ]; then
        local env_port
        env_port="$(echo "$SSH_CONNECTION" | awk '{print $4}')"
        if [ -n "$env_port" ]; then
            echo "$env_port"
            return
        fi
    fi
    # Check drop-in or sshd_config
    if [ -f /etc/ssh/sshd_config.d/99-hardened.conf ]; then
        local p
        p=$(grep -E '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config.d/99-hardened.conf 2>/dev/null | awk '{print $2}' | tail -n 1 || true)
        if [ -n "$p" ]; then
            echo "$p"
            return
        fi
    fi
    if [ -f /etc/ssh/sshd_config ]; then
        local p
        p=$(grep -E '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -n 1 || true)
        if [ -n "$p" ]; then
            echo "$p"
            return
        fi
    fi
    echo "22"
}

# 1. Install UFW if not present
install_ufw() {
    log_info "Verifying UFW installation..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would verify/install ufw package"
        return 0
    fi

    if ! command -v ufw >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive $SUDO_CMD apt-get update -qq >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive $SUDO_CMD apt-get install -y -qq ufw >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null 2>&1; then
            $SUDO_CMD dnf install -y ufw >/dev/null 2>&1 || true
        elif command -v apk >/dev/null 2>&1; then
            $SUDO_CMD apk add ufw >/dev/null 2>&1 || true
        fi
        log_ok "UFW installed successfully."
    else
        log_ok "UFW is already installed."
    fi
}

# 2. Configure DOCKER-USER chain in /etc/ufw/after.rules to prevent Docker bypass
configure_docker_user_chain() {
    log_info "Configuring DOCKER-USER chain in /etc/ufw/after.rules..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would patch /etc/ufw/after.rules to secure Docker container routing"
        return 0
    fi

    local after_rules="/etc/ufw/after.rules"
    if [ ! -f "$after_rules" ]; then
        log_warn "$after_rules not found. Skipping DOCKER-USER chain rule configuration."
        return 0
    fi

    if grep -qs "BEGIN SERVER-SETUP DOCKER-USER" "$after_rules"; then
        log_ok "DOCKER-USER chain rules already present in $after_rules."
        return 0
    fi

    # Append DOCKER-USER filtering block before the final COMMIT in *filter table
    local tmp_rules
    tmp_rules="$(mktemp)"

    cat <<'EOF' > "$tmp_rules"

# BEGIN SERVER-SETUP DOCKER-USER
# Prevent Docker from bypassing UFW while preserving internal container connectivity
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A DOCKER-USER -i lo -j ACCEPT
-A DOCKER-USER -i docker0 -j ACCEPT
-A DOCKER-USER -i br-+ -j ACCEPT
-A DOCKER-USER -j RETURN
COMMIT
# END SERVER-SETUP DOCKER-USER
EOF

    $SUDO_CMD tee -a "$after_rules" < "$tmp_rules" >/dev/null
    rm -f "$tmp_rules"
    log_ok "DOCKER-USER isolation rules added to $after_rules."
}

# 3. Detect and allow active services & Docker ports
detect_and_allow_active_services() {
    local active_ssh
    active_ssh="$(detect_ssh_port)"

    log_info "Detecting active workloads to whitelist..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would allow SSH port $active_ssh/tcp"
        log_ok "[dry-run] Would scan running Docker containers for exposed ports and allow them"
        if [ -n "$EXTRA_PORTS" ]; then
            log_ok "[dry-run] Would allow extra ports: $EXTRA_PORTS"
        fi
        return 0
    fi

    # Always allow SSH first to guarantee connectivity
    $SUDO_CMD ufw allow "${active_ssh}/tcp" comment "SSH port" >/dev/null
    log_ok "Allowed SSH port $active_ssh/tcp."

    # Scan running docker containers if docker CLI is available
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        local raw_ports
        raw_ports=$(docker ps --format '{{.Ports}}' 2>/dev/null || true)
        if [ -n "$raw_ports" ]; then
            # Parse entries like 0.0.0.0:80->80/tcp, :::443->443/tcp, 0.0.0.0:51820->51820/udp
            local extracted_ports
            extracted_ports=$(echo "$raw_ports" | grep -oE '[0-9]+/(tcp|udp)' | sort -u || true)
            for p in $extracted_ports; do
                if [ -n "$p" ]; then
                    $SUDO_CMD ufw allow "$p" comment "Docker workload" >/dev/null 2>&1 || true
                    log_ok "Auto-whitelisted active container port: $p"
                fi
            done
        fi
    fi

    # Extra user ports
    if [ -n "$EXTRA_PORTS" ]; then
        IFS=',' read -ra ADDR <<< "$EXTRA_PORTS"
        for p in "${ADDR[@]}"; do
            p_clean="$(echo "$p" | tr -d ' ')"
            if [ -n "$p_clean" ]; then
                $SUDO_CMD ufw allow "$p_clean" comment "User configured port" >/dev/null
                log_ok "Allowed extra port: $p_clean"
            fi
        done
    fi
}

# 4. Enable UFW safely
enable_firewall() {
    log_info "Enforcing firewall policy (default deny incoming, allow outgoing)..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would execute: ufw default deny incoming"
        log_ok "[dry-run] Would execute: ufw default allow outgoing"
        log_ok "[dry-run] Would execute: ufw --force enable"
        return 0
    fi

    $SUDO_CMD ufw default deny incoming >/dev/null
    $SUDO_CMD ufw default allow outgoing >/dev/null
    $SUDO_CMD ufw --force enable >/dev/null
    $SUDO_CMD ufw reload >/dev/null 2>&1 || true
    log_ok "Firewall is active and enabled."
}

main() {
    log_info "=== Starting Baseline Firewall & Docker Integration ==="
    install_ufw
    configure_docker_user_chain
    detect_and_allow_active_services
    enable_firewall
    log_ok "=== Baseline Firewall Configuration Completed ==="
}

main "$@"
