#!/usr/bin/env bash
# ==============================================================================
# core/preflight.sh - Pre-Flight Sanity Checks & Auto-Adaptation Engine
# Detects virtualization, checks port conflicts, inspects storage/inodes/RAM
# ==============================================================================

set -euo pipefail

log_info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
log_ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
log_err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --json                 Output preflight check results as JSON
  --dry-run              Simulate execution without modifying the host
  -h, --help             Show this help message
EOF
    exit 0
}

JSON_OUTPUT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)
            JSON_OUTPUT=1
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

# 1. Detect virtualization type
detect_virtualization() {
    local virt="bare-metal"

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        local d
        d="$(systemd-detect-virt 2>/dev/null || true)"
        if [ -n "$d" ] && [ "$d" != "none" ]; then
            virt="$d"
        fi
    fi

    if [ "$virt" = "bare-metal" ]; then
        if [ -f /proc/1/environ ] && grep -qa "container=" /proc/1/environ 2>/dev/null; then
            virt="$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep "^container=" | cut -d= -f2 || echo "container")"
        elif [ -f /.dockerenv ]; then
            virt="docker"
        fi
    fi

    echo "$virt"
}

# 2. Check for port conflicts (80, 443, 22, 53)
check_port_conflicts() {
    local conflicts=()
    local critical_ports=(80 443 22 53)

    for port in "${critical_ports[@]}"; do
        local listener=""
        if command -v ss >/dev/null 2>&1; then
            listener="$(ss -tulpn "sport = :$port" 2>/dev/null | tail -n +2 | head -n 1 || true)"
        fi

        if [ -n "$listener" ]; then
            local proc="unknown"
            if echo "$listener" | grep -q "docker"; then
                proc="docker"
            elif echo "$listener" | grep -q "systemd-resolve"; then
                proc="systemd-resolved"
            elif echo "$listener" | grep -q "nginx"; then
                proc="nginx"
            elif echo "$listener" | grep -q "apache"; then
                proc="apache"
            elif echo "$listener" | grep -q "sshd"; then
                proc="sshd"
            elif echo "$listener" | grep -q "caddy"; then
                proc="caddy"
            fi
            conflicts+=("$port:$proc")
        fi
    done

    echo "${conflicts[*]:-}"
}

# 3. Check memory, disk, and inodes
check_resources() {
    local mem_avail_mb=0
    if [ -f /proc/meminfo ]; then
        local mem_avail_kb
        mem_avail_kb="$(grep -w "MemAvailable:" /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)"
        mem_avail_mb=$(( mem_avail_kb / 1024 ))
    fi

    local disk_avail_mb=0
    disk_avail_mb="$(df -Pk / 2>/dev/null | awk 'NR==2 {print int($4/1024)}' || echo 0)"

    local inode_used_pct=0
    inode_used_pct="$(df -Pi / 2>/dev/null | awk 'NR==2 {gsub("%",""); print $5}' || echo 0)"

    echo "$mem_avail_mb $disk_avail_mb $inode_used_pct"
}

run_preflight() {
    local virt
    virt="$(detect_virtualization)"

    local is_container=0
    case "$virt" in
        lxc|openvz|docker|podman|container)
            is_container=1
            ;;
    esac

    local port_conflicts
    port_conflicts="$(check_port_conflicts)"

    read -r mem_avail_mb disk_avail_mb inode_used_pct <<< "$(check_resources)"

    local status="PASS"
    local issues=()

    if [ "$inode_used_pct" -ge 95 ]; then
        status="CRITICAL"
        issues+=("Root filesystem inodes nearly exhausted (${inode_used_pct}%). Package installation will fail.")
    fi

    if [ "$disk_avail_mb" -lt 500 ]; then
        status="CRITICAL"
        issues+=("Critically low disk space (${disk_avail_mb} MB available). Minimum 500 MB required.")
    elif [ "$disk_avail_mb" -lt 1024 ]; then
        [ "$status" != "CRITICAL" ] && status="WARN"
        issues+=("Low disk space (${disk_avail_mb} MB available). Consider expanding storage.")
    fi

    if [ "$mem_avail_mb" -gt 0 ] && [ "$mem_avail_mb" -lt 100 ]; then
        [ "$status" != "CRITICAL" ] && status="WARN"
        issues+=("Very low available memory (${mem_avail_mb} MB). Ensure swap/ZRAM is enabled.")
    fi

    if [ "$JSON_OUTPUT" -eq 1 ]; then
        cat <<EOF
{
  "status": "$status",
  "virtualization": "$virt",
  "is_container": $([ "$is_container" -eq 1 ] && echo "true" || echo "false"),
  "resources": {
    "available_memory_mb": $mem_avail_mb,
    "available_disk_mb": $disk_avail_mb,
    "inode_used_pct": $inode_used_pct
  },
  "port_conflicts": [$(for c in $port_conflicts; do echo "\"$c\","; done | sed '$ s/,$//')],
  "issues": [$(for i in "${issues[@]}"; do echo "\"$i\","; done | sed '$ s/,$//')]
}
EOF
        [ "$status" = "CRITICAL" ] && return 1 || return 0
    fi

    log_info "=== Running Pre-Flight Host Diagnostics ==="
    log_info "Virtualization:       $virt $([ "$is_container" -eq 1 ] && echo '(Container environment)' || echo '(Full Hypervisor/Hardware)')"
    log_info "Memory Available:     ${mem_avail_mb} MB"
    log_info "Disk Space Free:      ${disk_avail_mb} MB"
    log_info "Inodes Used:          ${inode_used_pct}%"

    if [ -n "$port_conflicts" ]; then
        log_info "Listening Ports:      $port_conflicts"
    fi

    if [ "$is_container" -eq 1 ]; then
        log_warn "Notice: Running inside container virtualization ($virt). Kernel module loading (ZRAM/BBR) will gracefully adapt."
        export SKIP_KERNEL_MODS=1
    fi

    if [ "${#issues[@]}" -gt 0 ]; then
        for issue in "${issues[@]}"; do
            if [ "$status" = "CRITICAL" ]; then
                log_err "$issue"
            else
                log_warn "$issue"
            fi
        done
    fi

    if [ "$status" = "CRITICAL" ]; then
        log_err "Pre-flight validation FAILED. Resolve critical resource constraints before proceeding."
        return 1
    fi

    log_ok "Pre-flight checks passed ($status). Safe to proceed."
    return 0
}

run_preflight
