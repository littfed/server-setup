#!/usr/bin/env bash
# ==============================================================================
# modules/maintenance/auto-prune.sh - Automated Safe Docker Garbage Collection
# Configures a low-priority systemd timer to purge dangling images & build cache
# Preserves active containers and data volumes!
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

# 1. Standalone prune execution (can be run directly or via systemd)
execute_prune() {
    local filter_age="${1:-168h}" # Default 7 days
    local threshold_pct="${2:-0}"  # If >0, only prune when disk > threshold

    if [ "$threshold_pct" -gt 0 ]; then
        local current_pct
        current_pct="$(df -P /var/lib/docker 2>/dev/null | awk 'NR==2 {gsub("%",""); print $5}' || df -P / | awk 'NR==2 {gsub("%",""); print $5}')"
        if [ "$current_pct" -lt "$threshold_pct" ]; then
            log_info "Disk usage ($current_pct%) is below threshold ($threshold_pct%). Prune skipped."
            return 0
        fi
        log_info "Disk usage ($current_pct%) exceeds threshold ($threshold_pct%). Running prune..."
    fi

    log_info "Executing safe Docker system prune (filter: until=$filter_age)..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would execute: nice -n 19 ionice -c 3 docker system prune -f --filter until=$filter_age"
        return 0
    fi

    if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
        # Run with lowest CPU and I/O scheduling priority so user apps are unaffected
        nice -n 19 ionice -c 3 docker system prune -f --filter "until=$filter_age" >/dev/null 2>&1 || true
        nice -n 19 ionice -c 3 docker builder prune -f --filter "until=$filter_age" >/dev/null 2>&1 || true
        log_ok "Docker auto-prune completed successfully."
    else
        log_warn "Docker is not running; prune skipped."
    fi
}

# 2. Install systemd timer and service
install_auto_prune_service() {
    local schedule="${1:-weekly}" # e.g. weekly or Sun *-*-* 03:00:00
    local filter_age="${2:-168h}"

    log_info "Installing Docker auto-prune systemd service and timer ($schedule)..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would create /etc/systemd/system/docker-auto-prune.{service,timer}"
        return 0
    fi

    # Create helper script invoked by systemd
    $SUDO_CMD mkdir -p /usr/local/bin
    cat <<EOF | $SUDO_CMD tee /usr/local/bin/docker-auto-prune.sh >/dev/null
#!/usr/bin/env bash
set -e
if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
    nice -n 19 ionice -c 3 docker system prune -f --filter "until=$filter_age" >/dev/null 2>&1 || true
    nice -n 19 ionice -c 3 docker builder prune -f --filter "until=$filter_age" >/dev/null 2>&1 || true
fi
EOF
    $SUDO_CMD chmod 755 /usr/local/bin/docker-auto-prune.sh

    # Systemd Service
    cat <<'EOF' | $SUDO_CMD tee /etc/systemd/system/docker-auto-prune.service >/dev/null
[Unit]
Description=Docker Safe Auto Prune Service
Documentation=https://github.com/littfed/server-setup
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/docker-auto-prune.sh
Nice=19
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF

    # Systemd Timer
    cat <<EOF | $SUDO_CMD tee /etc/systemd/system/docker-auto-prune.timer >/dev/null
[Unit]
Description=Docker Safe Auto Prune Weekly Timer
Documentation=https://github.com/littfed/server-setup

[Timer]
OnCalendar=Sun *-*-* 03:30:00
Persistent=true
RandomizedDelaySec=1800

[Install]
WantedBy=timers.target
EOF

    if command -v systemctl >/dev/null 2>&1; then
        $SUDO_CMD systemctl daemon-reload >/dev/null 2>&1 || true
        $SUDO_CMD systemctl enable --now docker-auto-prune.timer >/dev/null 2>&1 || true
        log_ok "docker-auto-prune.timer enabled and running."
    else
        log_warn "systemd not available; falling back to cron..."
        echo "30 3 * * 0 root /usr/local/bin/docker-auto-prune.sh >/dev/null 2>&1" | $SUDO_CMD tee /etc/cron.d/docker-auto-prune >/dev/null
        log_ok "Cron job /etc/cron.d/docker-auto-prune configured."
    fi
}

main() {
    local action="install"
    local filter_age="168h"
    local threshold=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --run-now) action="run"; shift ;;
            --filter-age) filter_age="$2"; shift 2 ;;
            --threshold) threshold="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [ "$action" = "run" ]; then
        execute_prune "$filter_age" "$threshold"
    else
        install_auto_prune_service "weekly" "$filter_age"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
