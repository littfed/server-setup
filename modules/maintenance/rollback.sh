#!/usr/bin/env bash
# ==============================================================================
# modules/maintenance/rollback.sh - Automated Backup & State Restoration Engine
# Creates pre-flight snapshots and enables atomic rollback of host configurations
# ==============================================================================

set -euo pipefail

log_info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
log_ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
log_err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

get_sudo() {
    if [ "${DRY_RUN:-0}" = "1" ] || [ "${ACTION:-}" = "list" ]; then
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
Usage: $0 [action] [options]

Actions:
  snapshot               Create a pre-flight snapshot of all manageable host configs
  restore [timestamp]    Restore configurations from specific or latest snapshot
  list                   List available backup snapshots

Options:
  --backup-dir <dir>     Custom backup root directory (default: /var/backups/server-setup)
  --dry-run              Simulate execution without modifying files
  -h, --help             Show this help message
EOF
    exit 0
}

ACTION="snapshot"
TARGET_SNAPSHOT="latest"
BACKUP_ROOT="/var/backups/server-setup"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        snapshot)
            ACTION="snapshot"
            shift
            ;;
        restore)
            ACTION="restore"
            shift
            if [[ $# -gt 0 ]] && [[ "$1" != --* ]]; then
                TARGET_SNAPSHOT="$1"
                shift
            fi
            ;;
        list)
            ACTION="list"
            shift
            ;;
        --backup-dir)
            BACKUP_ROOT="$2"
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

# Config files tracked by server-setup
TRACKED_FILES=(
    "/etc/ssh/sshd_config"
    "/etc/ssh/sshd_config.d/99-hardened.conf"
    "/etc/docker/daemon.json"
    "/etc/sysctl.d/99-bbr.conf"
    "/etc/sysctl.d/99-network-security.conf"
    "/etc/sysctl.d/99-file-max.conf"
    "/etc/security/limits.d/99-nofile.conf"
    "/etc/systemd/system.conf.d/limits.conf"
    "/etc/systemd/timesyncd.conf.d/99-ntp.conf"
    "/etc/ufw/after.rules"
    "/etc/fail2ban/jail.d/ssh-hardened.local"
)

# 1. Create Pre-Flight Snapshot
create_snapshot() {
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    local snap_dir="$BACKUP_ROOT/$ts"

    log_info "Creating pre-flight configuration snapshot..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would snapshot tracked configurations to $snap_dir"
        return 0
    fi

    $SUDO_CMD mkdir -p "$snap_dir"

    local backed_up_count=0
    for f in "${TRACKED_FILES[@]}"; do
        if [ -f "$f" ]; then
            local rel_dir
            rel_dir="$(dirname "$f")"
            $SUDO_CMD mkdir -p "$snap_dir$rel_dir"
            $SUDO_CMD cp -p "$f" "$snap_dir$f"
            backed_up_count=$(( backed_up_count + 1 ))
        fi
    done

    # Write manifest
    cat <<EOF | $SUDO_CMD tee "$snap_dir/manifest.json" >/dev/null
{
  "timestamp": "$ts",
  "hostname": "$(hostname)",
  "backed_up_files_count": $backed_up_count,
  "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

    # Prune old snapshots, keep last 10
    local all_snaps
    all_snaps=$(ls -1d "$BACKUP_ROOT"/[0-9]* 2>/dev/null | sort || true)
    local total_count
    total_count=$(echo "$all_snaps" | grep -c . || echo 0)
    if [ "$total_count" -gt 10 ]; then
        local to_delete=$(( total_count - 10 ))
        echo "$all_snaps" | head -n "$to_delete" | while read -r old_dir; do
            [ -n "$old_dir" ] && $SUDO_CMD rm -rf "$old_dir"
        done
    fi

    log_ok "Snapshot $ts created successfully ($backed_up_count files preserved)."
}

# 2. List Available Snapshots
list_snapshots() {
    log_info "=== Available Server-Setup Snapshots ==="
    if [ ! -d "$BACKUP_ROOT" ]; then
        log_info "No snapshots found in $BACKUP_ROOT."
        return 0
    fi

    local count=0
    for snap_dir in "$BACKUP_ROOT"/[0-9]*; do
        if [ -d "$snap_dir" ]; then
            local ts
            ts="$(basename "$snap_dir")"
            local files_info="manifest missing"
            if [ -f "$snap_dir/manifest.json" ]; then
                files_info=$(grep -oE '"backed_up_files_count": [0-9]+' "$snap_dir/manifest.json" | sed 's/"//g' || echo "manifest ok")
            fi
            echo -e "  \033[1;36m• $ts\033[0m ($files_info) -> $snap_dir"
            count=$(( count + 1 ))
        fi
    done

    if [ "$count" -eq 0 ]; then
        log_info "No snapshots found in $BACKUP_ROOT."
    fi
}

# 3. Restore Configurations from Snapshot
restore_snapshot() {
    local target="$TARGET_SNAPSHOT"
    local snap_dir=""

    if [ "$target" = "latest" ]; then
        snap_dir="$(ls -1d "$BACKUP_ROOT"/[0-9]* 2>/dev/null | sort | tail -n 1 || true)"
        if [ -z "$snap_dir" ]; then
            if [ "${DRY_RUN:-0}" = "1" ]; then
                log_ok "[dry-run] Would identify latest snapshot and restore all tracked configurations"
                return 0
            fi
            log_err "No existing snapshots found in $BACKUP_ROOT to restore from!"
            exit 1
        fi
    else
        if [ -d "$BACKUP_ROOT/$target" ]; then
            snap_dir="$BACKUP_ROOT/$target"
        elif [ -d "$target" ]; then
            snap_dir="$target"
        else
            if [ "${DRY_RUN:-0}" = "1" ]; then
                log_ok "[dry-run] Would restore configurations from snapshot: $target"
                return 0
            fi
            log_err "Snapshot not found: $target"
            exit 1
        fi
    fi

    local snap_name
    snap_name="$(basename "$snap_dir")"
    log_info "Restoring system configurations from snapshot: $snap_name..."

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would restore files from $snap_dir, run 'sshd -t' check, and reload services"
        return 0
    fi

    # 1. Restore backed up files
    for f in "${TRACKED_FILES[@]}"; do
        if [ -f "$snap_dir$f" ]; then
            $SUDO_CMD mkdir -p "$(dirname "$f")"
            $SUDO_CMD cp -p "$snap_dir$f" "$f"
            log_ok "Restored: $f"
        elif [ -f "$f" ]; then
            # If the file was NOT present in snapshot, remove it (it was generated by server-setup)
            $SUDO_CMD rm -f "$f"
            log_ok "Removed generated drop-in: $f"
        fi
    done

    # 2. Validate SSH syntax before reloading
    if command -v sshd >/dev/null 2>&1; then
        log_info "Validating SSH syntax with sshd -t..."
        if ! $SUDO_CMD sshd -t; then
            log_err "CRITICAL: sshd -t syntax test failed after restore! Check SSH configs immediately."
            exit 1
        fi
        log_ok "SSH syntax valid."
    fi

    # 3. Reload services
    if command -v sysctl >/dev/null 2>&1; then
        $SUDO_CMD sysctl --system >/dev/null 2>&1 || true
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet ssh 2>/dev/null; then
            $SUDO_CMD systemctl reload ssh || $SUDO_CMD systemctl restart ssh || true
        elif systemctl is-active --quiet sshd 2>/dev/null; then
            $SUDO_CMD systemctl reload sshd || $SUDO_CMD systemctl restart sshd || true
        fi
        if systemctl is-active --quiet ufw 2>/dev/null; then
            $SUDO_CMD ufw reload >/dev/null 2>&1 || true
        fi
        if systemctl is-active --quiet fail2ban 2>/dev/null; then
            $SUDO_CMD systemctl restart fail2ban >/dev/null 2>&1 || true
        fi
    fi

    log_ok "=== Rollback to Snapshot $snap_name Completed Successfully ==="
}

main() {
    case "$ACTION" in
        snapshot)
            create_snapshot
            ;;
        list)
            list_snapshots
            ;;
        restore)
            restore_snapshot
            ;;
        *)
            log_err "Unknown action: $ACTION"
            usage
            ;;
    esac
}

main "$@"
