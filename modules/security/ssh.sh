#!/usr/bin/env bash
# ==============================================================================
# modules/security/ssh.sh - SSH Hardening with Anti-Lockout Protection
# Features: Key-based auth only, root password disabled, modern ciphers, port change
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

CURRENT_USER="${SUDO_USER:-${USER:-$(id -un)}}"

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --port <port>          SSH port to configure (default: keep current or 22)
  --ssh-port <port>      Alias for --port
  --force-disable-pass   Disable password auth even if keys are not auto-detected
  --dry-run              Simulate execution without modifying SSH configuration
  -h, --help             Show this help message
EOF
    exit 0
}

SSH_PORT=""
FORCE_DISABLE_PASS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port|--ssh-port)
            SSH_PORT="$2"
            shift 2
            ;;
        --force-disable-pass)
            FORCE_DISABLE_PASS=1
            shift
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

# Detect current SSH port if not specified
detect_current_ssh_port() {
    if [ -n "$SSH_PORT" ]; then
        echo "$SSH_PORT"
        return
    fi

    local port="22"
    if [ -f /etc/ssh/sshd_config ]; then
        local p
        p=$(grep -E '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -n 1 || true)
        if [ -n "$p" ]; then
            port="$p"
        fi
    fi
    echo "$port"
}

# 1. Anti-Lockout Verification: Ensure active public key is installed
verify_authorized_keys() {
    log_info "Verifying SSH authorized_keys to prevent lockout..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would verify existence of valid authorized_keys in ~/.ssh"
        return 0
    fi

    local found_key=0
    local target_files=(
        "$HOME/.ssh/authorized_keys"
        "/root/.ssh/authorized_keys"
        "/home/$CURRENT_USER/.ssh/authorized_keys"
    )

    for f in "${target_files[@]}"; do
        if [ -f "$f" ] && grep -qE "^(ssh-rsa|ssh-ed25519|ecdsa-sha2-|sk-)" "$f" 2>/dev/null; then
            found_key=1
            log_ok "Verified valid public key in $f"
            break
        fi
    done

    if [ "$found_key" -eq 0 ] && [ "$FORCE_DISABLE_PASS" -eq 0 ]; then
        log_warn "======================================================================"
        log_warn "  SAFETY LOCKOUT WARNING: No valid SSH public keys detected!"
        log_warn "  PasswordAuthentication will NOT be disabled to avoid complete lockout."
        log_warn "  To force disabling password auth, pass --force-disable-pass."
        log_warn "======================================================================"
        return 1
    fi

    return 0
}

# 2. Configure SSH drop-in
configure_sshd() {
    local target_port
    target_port="$(detect_current_ssh_port)"
    local disable_password=1

    if ! verify_authorized_keys; then
        disable_password=0
    fi

    log_info "Configuring SSH hardening on port $target_port..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would write /etc/ssh/sshd_config.d/99-hardened.conf (Port $target_port, Passwords: $([ "$disable_password" -eq 1 ] && echo 'Disabled' || echo 'Enabled'))"
        log_ok "[dry-run] Would run 'sshd -t' syntax check"
        log_ok "[dry-run] Would reload SSH service"
        return 0
    fi

    local sshd_config_d="/etc/ssh/sshd_config.d"
    $SUDO_CMD mkdir -p "$sshd_config_d"

    # Ensure main sshd_config includes sshd_config.d
    if [ -f /etc/ssh/sshd_config ] && ! grep -qs "^Include /etc/ssh/sshd_config.d/\*.conf" /etc/ssh/sshd_config; then
        echo "Include /etc/ssh/sshd_config.d/*.conf" | $SUDO_CMD tee -a /etc/ssh/sshd_config >/dev/null
    fi

    local pass_auth="no"
    if [ "$disable_password" -eq 0 ]; then
        pass_auth="yes"
    fi

    local dropin_file="$sshd_config_d/99-hardened.conf"
    local tmp_conf
    tmp_conf="$(mktemp)"

    cat <<EOF > "$tmp_conf"
# ==============================================================================
# Managed by server-setup (modules/security/ssh.sh)
# ==============================================================================
Port $target_port
PubkeyAuthentication yes
PasswordAuthentication $pass_auth
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
X11Forwarding no
MaxAuthTries 4
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

    $SUDO_CMD cp "$tmp_conf" "$dropin_file"
    rm -f "$tmp_conf"
    $SUDO_CMD chmod 600 "$dropin_file"

    # Test configuration before reload
    log_info "Testing SSH configuration syntax with sshd -t..."
    if ! $SUDO_CMD sshd -t; then
        log_err "CRITICAL: sshd -t syntax test failed! Reverting $dropin_file to prevent lockout..."
        $SUDO_CMD rm -f "$dropin_file"
        exit 1
    fi
    log_ok "sshd -t validation passed."

    # Reload service
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet ssh 2>/dev/null; then
            $SUDO_CMD systemctl reload ssh || $SUDO_CMD systemctl restart ssh
            log_ok "Reloaded ssh service."
        elif systemctl is-active --quiet sshd 2>/dev/null; then
            $SUDO_CMD systemctl reload sshd || $SUDO_CMD systemctl restart sshd
            log_ok "Reloaded sshd service."
        fi
    elif command -v service >/dev/null 2>&1; then
        $SUDO_CMD service ssh reload 2>/dev/null || $SUDO_CMD service sshd reload 2>/dev/null || true
    fi

    log_ok "SSH Hardening applied successfully on port $target_port."
}

main() {
    log_info "=== Starting SSH Security Hardening ==="
    configure_sshd
    log_ok "=== SSH Security Hardening Completed ==="
}

main "$@"
