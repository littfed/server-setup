#!/usr/bin/env bash
# ==============================================================================
# modules/telemetry/health-cron.sh - Zero-Overhead Server Health Telemetry
# Reads /proc directly and sends heartbeats / alerts to Webhooks or Telegram
# Memory footprint: 0 MB resident RAM (runs on cron, exits in <0.5s)
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
        echo ""
    fi
}

SUDO_CMD="$(get_sudo)"

# 1. Gather metrics directly from kernel interfaces
sample_metrics() {
    local hostname
    hostname="$(hostname)"

    # Memory from /proc/meminfo
    local mem_total_kb mem_avail_kb
    mem_total_kb="$(grep -w "MemTotal:" /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 1024000)"
    mem_avail_kb="$(grep -w "MemAvailable:" /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 512000)"
    local mem_used_kb=$((mem_total_kb - mem_avail_kb))
    local mem_used_pct=$(( (mem_used_kb * 100) / mem_total_kb ))

    # Disk usage of root /
    local disk_used_pct
    disk_used_pct="$(df -P / 2>/dev/null | awk 'NR==2 {gsub("%",""); print $5}' || echo 0)"

    # Load average from /proc/loadavg
    local load_1m
    load_1m="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0.0")"

    # Running Docker containers count
    local containers_count=0
    if command -v docker >/dev/null 2>&1 && [ -S /var/run/docker.sock ]; then
        containers_count="$(docker ps -q 2>/dev/null | wc -l || echo 0)"
    fi

    # Format JSON payload
    cat <<EOF
{
  "host": "$hostname",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "metrics": {
    "memory_used_pct": $mem_used_pct,
    "memory_used_mb": $((mem_used_kb / 1024)),
    "memory_total_mb": $((mem_total_kb / 1024)),
    "disk_used_pct": $disk_used_pct,
    "load_1m": $load_1m,
    "running_containers": $containers_count
  }
}
EOF
}

# 2. Dispatch payload to configured destination
send_telemetry() {
    local webhook_url="${1:-}"
    local telegram_bot_token="${2:-}"
    local telegram_chat_id="${3:-}"

    local payload
    payload="$(sample_metrics)"

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Sampled payload: $payload"
        return 0
    fi

    # Webhook POST
    if [ -n "$webhook_url" ]; then
        curl -sSL -m 5 -X POST \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "$webhook_url" >/dev/null 2>&1 || true
    fi

    # Telegram Alert
    if [ -n "$telegram_bot_token" ] && [ -n "$telegram_chat_id" ]; then
        local mem_pct
        mem_pct="$(echo "$payload" | jq -r '.metrics.memory_used_pct')"
        local disk_pct
        disk_pct="$(echo "$payload" | jq -r '.metrics.disk_used_pct')"
        local host
        host="$(echo "$payload" | jq -r '.host')"

        local msg="🖥 *Server Health Alert:* \`$host\`%0ARAM: *${mem_pct}%*%0ADisk: *${disk_pct}%*"
        curl -sSL -m 5 "https://api.telegram.org/bot${telegram_bot_token}/sendMessage?chat_id=${telegram_chat_id}&text=${msg}&parse_mode=Markdown" >/dev/null 2>&1 || true
    fi
}

# 3. Setup periodic cron job
install_telemetry_cron() {
    local interval_min="${1:-5}"
    local webhook_url="${2:-}"
    local tg_token="${3:-}"
    local tg_chat="${4:-}"

    log_info "Installing zero-overhead telemetry cron job (every $interval_min min)..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_ok "[dry-run] Would create /etc/cron.d/server-setup-telemetry"
        return 0
    fi

    $SUDO_CMD mkdir -p /usr/local/bin
    cat <<EOF | $SUDO_CMD tee /usr/local/bin/server-setup-telemetry.sh >/dev/null
#!/usr/bin/env bash
/usr/local/bin/health-cron.sh --send-now --webhook-url "$webhook_url" --tg-token "$tg_token" --tg-chat "$tg_chat" >/dev/null 2>&1
EOF
    $SUDO_CMD cp "${BASH_SOURCE[0]}" /usr/local/bin/health-cron.sh
    $SUDO_CMD chmod 755 /usr/local/bin/health-cron.sh /usr/local/bin/server-setup-telemetry.sh

    echo "*/$interval_min * * * * root /usr/local/bin/server-setup-telemetry.sh" | $SUDO_CMD tee /etc/cron.d/server-setup-telemetry >/dev/null
    $SUDO_CMD chmod 644 /etc/cron.d/server-setup-telemetry
    log_ok "Zero-overhead telemetry cron job installed at /etc/cron.d/server-setup-telemetry."
}

main() {
    local action="sample"
    local webhook_url=""
    local tg_token=""
    local tg_chat=""
    local interval=5

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --send-now) action="send"; shift ;;
            --install-cron) action="install"; shift ;;
            --webhook-url) webhook_url="$2"; shift 2 ;;
            --tg-token) tg_token="$2"; shift 2 ;;
            --tg-chat) tg_chat="$2"; shift 2 ;;
            --interval) interval="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    case "$action" in
        sample) sample_metrics ;;
        send) send_telemetry "$webhook_url" "$tg_token" "$tg_chat" ;;
        install) install_telemetry_cron "$interval" "$webhook_url" "$tg_token" "$tg_chat" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
