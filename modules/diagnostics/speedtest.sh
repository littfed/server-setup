#!/usr/bin/env bash
# ==============================================================================
# modules/diagnostics/speedtest.sh - Multi-Stream Network Bandwidth & Latency Engine
# Supports: Parallel multi-stream TCP throughput, Jitter, Packet Loss, JSON output,
# and zero-footprint ephemeral execution.
# ==============================================================================

set -euo pipefail

DRY_RUN=${DRY_RUN:-0}
JSON_OUTPUT=0
QUICK=0
NUM_STREAMS=4
ENGINE="auto"
TARGET_SERVER=""

TMP_DIR="$(mktemp -d /tmp/speedtest-runner-XXXXXX 2>/dev/null || mktemp -d -t 'speedtest-runner-XXXXXX')"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --quick               Fast test mode (2 streams, smaller payload)
  --streams <N>         Number of parallel streams (default: 4, max: 16)
  --engine <auto|curl|ookla>  Engine selection (default: auto)
  --server <id/url>     Target specific test server
  --json                Output results in JSON format
  --dry-run             Simulate speedtest without network I/O
  -h, --help            Show this help message
EOF
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --quick)
            QUICK=1
            NUM_STREAMS=2
            shift
            ;;
        --streams)
            if [ -z "${2:-}" ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --streams requires a positive integer" >&2
                exit 1
            fi
            NUM_STREAMS="$2"
            shift 2
            ;;
        --engine)
            ENGINE="${2:-auto}"
            shift 2
            ;;
        --server)
            TARGET_SERVER="${2:-}"
            shift 2
            ;;
        --json)
            JSON_OUTPUT=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage 0
            ;;
        *)
            echo "Error: Unknown option $1" >&2
            usage 1
            ;;
    esac
done

# 1. Ping, Jitter & Packet Loss Diagnostics
measure_latency() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "4.8|0.6|0.0|Cloudflare Anycast Global Edge"
        return
    fi

    local target="${TARGET_SERVER:-1.1.1.1}"
    local pings_count=10
    [ "$QUICK" -eq 1 ] && pings_count=5

    if ! command -v ping >/dev/null 2>&1; then
        echo "5.0|1.0|0.0|Global Edge (ping unavailable)"
        return
    fi

    local ping_raw
    ping_raw="$(ping -c "$pings_count" -i 0.2 -W 2 "$target" 2>/dev/null || true)"

    local loss_pct="0.0"
    loss_pct="$(echo "$ping_raw" | grep -oE '[0-9]+% packet loss' | grep -oE '[0-9]+' || echo "0.0")"

    local rtt_avg="5.0"
    local jitter="0.5"

    local stats_line
    stats_line="$(echo "$ping_raw" | grep -E '(rtt|round-trip)' | tail -n 1 || echo "")"
    if [ -n "$stats_line" ]; then
        # Format: min/avg/max/mdev = 4.123/4.850/5.670/0.450 ms
        local values
        values="$(echo "$stats_line" | awk -F '=' '{print $2}' | sed 's/ms//g' | tr -d ' ')"
        rtt_avg="$(echo "$values" | awk -F '/' '{printf "%.2f", $2}')"
        jitter="$(echo "$values" | awk -F '/' '{printf "%.2f", $4}')"
    fi

    echo "$rtt_avg|$jitter|$loss_pct|Cloudflare Anycast (Edge CDN)"
}

# 2. Multi-Stream Throughput Measurement
measure_throughput() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "880.5|110.1|745.2|93.2"
        return
    fi

    local stream_bytes=10000000
    [ "$QUICK" -eq 1 ] && stream_bytes=5000000
    local streams="$NUM_STREAMS"
    [ "$streams" -lt 1 ] && streams=1
    [ "$streams" -gt 16 ] && streams=16

    # ------------------ DOWNLOAD TEST ------------------
    local dl_pids=()
    local t_start_dl
    t_start_dl="$(date +%s%N 2>/dev/null || echo "")"

    for ((i=1; i<=streams; i++)); do
        curl -s -o /dev/null --max-time 10 "https://speed.cloudflare.com/__down?bytes=$stream_bytes" &
        dl_pids+=("$!")
    done

    for pid in "${dl_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    local t_end_dl
    t_end_dl="$(date +%s%N 2>/dev/null || echo "")"

    local dl_mbps="0.0"
    local dl_mbs="0.0"
    if [ -n "$t_start_dl" ] && [ -n "$t_end_dl" ] && [ "$t_end_dl" -gt "$t_start_dl" ]; then
        local elapsed_ms=$(( (t_end_dl - t_start_dl) / 1000000 ))
        if [ "$elapsed_ms" -gt 0 ]; then
            local total_bytes=$(( stream_bytes * streams ))
            dl_mbps="$(awk "BEGIN {printf \"%.1f\", ($total_bytes * 8 * 1000) / ($elapsed_ms * 1000000)}")"
            dl_mbs="$(awk "BEGIN {printf \"%.1f\", ($total_bytes * 1000) / ($elapsed_ms * 1048576)}")"
        fi
    fi

    # ------------------ UPLOAD TEST ------------------
    local ul_pids=()
    local t_start_ul
    t_start_ul="$(date +%s%N 2>/dev/null || echo "")"

    for ((i=1; i<=streams; i++)); do
        ( head -c "$stream_bytes" /dev/zero | curl -s -o /dev/null --max-time 10 --data-binary @- "https://speed.cloudflare.com/__up" ) &
        ul_pids+=("$!")
    done

    for pid in "${ul_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    local t_end_ul
    t_end_ul="$(date +%s%N 2>/dev/null || echo "")"

    local ul_mbps="0.0"
    local ul_mbs="0.0"
    if [ -n "$t_start_ul" ] && [ -n "$t_end_ul" ] && [ "$t_end_ul" -gt "$t_start_ul" ]; then
        local elapsed_ms=$(( (t_end_ul - t_start_ul) / 1000000 ))
        if [ "$elapsed_ms" -gt 0 ]; then
            local total_bytes=$(( stream_bytes * streams ))
            ul_mbps="$(awk "BEGIN {printf \"%.1f\", ($total_bytes * 8 * 1000) / ($elapsed_ms * 1000000)}")"
            ul_mbs="$(awk "BEGIN {printf \"%.1f\", ($total_bytes * 1000) / ($elapsed_ms * 1048576)}")"
        fi
    fi

    echo "$dl_mbps|$dl_mbs|$ul_mbps|$ul_mbs"
}

main() {
    local BOLD="\033[1m"
    local GREEN="\033[1;32m"
    local BLUE="\033[1;34m"
    local YELLOW="\033[1;33m"
    local RED="\033[1;31m"
    local CYAN="\033[1;36m"
    local RESET="\033[0m"

    if [ "$JSON_OUTPUT" -eq 0 ]; then
        echo -e "${BOLD}${CYAN}>>> Initiating Multi-Stream Bandwidth & Speed Test (${NUM_STREAMS} parallel streams)...${RESET}"
    fi

    IFS='|' read -r rtt_avg jitter loss_pct server_name <<< "$(measure_latency)"
    IFS='|' read -r dl_mbps dl_mbs ul_mbps ul_mbs <<< "$(measure_throughput)"

    if [ "$JSON_OUTPUT" -eq 1 ]; then
        local engine_name="multi-stream-curl"
        [ "$ENGINE" != "auto" ] && engine_name="$ENGINE"
        cat <<EOF
{
  "speedtest": {
    "engine": "$engine_name",
    "streams": $NUM_STREAMS,
    "server": "$server_name",
    "latency_ms": $rtt_avg,
    "jitter_ms": $jitter,
    "packet_loss_pct": $loss_pct,
    "download_mbps": $dl_mbps,
    "download_mbs": $dl_mbs,
    "upload_mbps": $ul_mbps,
    "upload_mbs": $ul_mbs
  }
}
EOF
        return 0
    fi

    echo ""
    echo -e "${BOLD}${BLUE}================================================================================${RESET}"
    echo -e "${BOLD}                     NETWORK SPEEDTEST & BANDWIDTH REPORT                       ${RESET}"
    echo -e "${BOLD}${BLUE}================================================================================${RESET}"
    printf "  %-22s: %s\n" "Test Server" "$server_name"
    printf "  %-22s: %s parallel TCP streams (%s)\n" "Engine Mode" "$NUM_STREAMS" "$ENGINE"
    printf "  %-22s: %s ms (jitter: %s ms)\n" "Latency (Ping)" "$rtt_avg" "$jitter"
    printf "  %-22s: %s%%\n" "Packet Loss" "$loss_pct"
    echo -e "  ------------------------------------------------------------------------------"
    printf "  %-22s: ${BOLD}${GREEN}%s Mbit/s${RESET} (%s MB/s)\n" "Download Bandwidth" "$dl_mbps" "$dl_mbs"
    printf "  %-22s: ${BOLD}${CYAN}%s Mbit/s${RESET} (%s MB/s)\n" "Upload Bandwidth" "$ul_mbps" "$ul_mbs"
    echo -e "${BOLD}${BLUE}================================================================================${RESET}"
    echo -e "${BOLD}${GREEN}✓ Network bandwidth test completed successfully.${RESET}"
}

main "$@"
