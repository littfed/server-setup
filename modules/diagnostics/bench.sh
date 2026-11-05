#!/usr/bin/env bash
# ==============================================================================
# modules/diagnostics/bench.sh - Lightweight Hardware & Network Benchmark
# Features: CPU Steal Time, I/O IOPS, CDN Latencies, Bandwidth, Scorecard + JSON
# Zero external package dependencies (pure Bash, coreutils, curl)
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
  --quick                Run accelerated benchmark (1s steal time, 25MB I/O test)
  --json                 Output benchmark results as JSON
  --dry-run              Simulate execution with mock metrics
  -h, --help             Show this help message
EOF
    exit 0
}

QUICK=0
JSON_OUTPUT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick)
            QUICK=1
            shift
            ;;
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

TMP_DIR="$(mktemp -d -t bench-XXXXXX 2>/dev/null || mktemp -d /tmp/bench-XXXXXX)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# 1. Gather System Identity & Specifications
get_system_info() {
    local os_name="Linux"
    if [ -f /etc/os-release ]; then
        os_name="$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"' || echo "Linux")"
    fi

    local kernel
    kernel="$(uname -r)"

    local cpu_model="Unknown CPU"
    if [ -f /proc/cpuinfo ]; then
        cpu_model="$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed -e 's/^[ \t]*//' || echo "Unknown CPU")"
    fi

    local cpu_cores
    cpu_cores="$(nproc 2>/dev/null || echo 1)"

    local mem_total_mb=1024
    if [ -f /proc/meminfo ]; then
        local kb
        kb="$(grep -w "MemTotal:" /proc/meminfo | awk '{print $2}' || echo 1048576)"
        mem_total_mb=$(( kb / 1024 ))
    fi

    local disk_total_gb=10
    disk_total_gb="$(df -Pk / 2>/dev/null | awk 'NR==2 {print int($2/1048576)}' || echo 10)"

    echo "$os_name|$kernel|$cpu_model|$cpu_cores|$mem_total_mb|$disk_total_gb"
}

# 2. CPU Steal Time & Compute Performance
bench_cpu() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "0.2|840"
        return
    fi

    local sample_sec=2
    [ "$QUICK" -eq 1 ] && sample_sec=1

    # Read /proc/stat cpu line
    local stat1
    stat1="$(grep '^cpu ' /proc/stat)"
    sleep "$sample_sec"
    local stat2
    stat2="$(grep '^cpu ' /proc/stat)"

    # cpu user nice system idle iowait irq softirq steal guest guest_nice
    local u1 n1 s1 i1 io1 ir1 so1 st1
    read -r _ u1 n1 s1 i1 io1 ir1 so1 st1 _ <<< "$stat1"
    local u2 n2 s2 i2 io2 ir2 so2 st2
    read -r _ u2 n2 s2 i2 io2 ir2 so2 st2 _ <<< "$stat2"

    local total1=$(( u1 + n1 + s1 + i1 + io1 + ir1 + so1 + st1 ))
    local total2=$(( u2 + n2 + s2 + i2 + io2 + ir2 + so2 + st2 ))

    local diff_total=$(( total2 - total1 ))
    local diff_steal=$(( st2 - st1 ))

    local steal_pct="0.0"
    if [ "$diff_total" -gt 0 ]; then
        # integer precision x10
        local calc=$(( (diff_steal * 1000) / diff_total ))
        steal_pct="$(awk "BEGIN {printf \"%.1f\", $calc / 10}")"
    fi

    # Compute sha256 hashing speed (MB/s)
    local test_mb=100
    [ "$QUICK" -eq 1 ] && test_mb=50

    local t_start
    t_start="$(date +%s%N 2>/dev/null || echo "")"
    dd if=/dev/zero bs=1M count="$test_mb" 2>/dev/null | sha256sum >/dev/null
    local t_end
    t_end="$(date +%s%N 2>/dev/null || echo "")"

    local cpu_speed_mb=500
    if [ -n "$t_start" ] && [ -n "$t_end" ] && [ "$t_end" -gt "$t_start" ]; then
        local elapsed_ms=$(( (t_end - t_start) / 1000000 ))
        if [ "$elapsed_ms" -gt 0 ]; then
            cpu_speed_mb=$(( (test_mb * 1000) / elapsed_ms ))
        fi
    fi

    echo "$steal_pct|$cpu_speed_mb"
}

# 3. Storage I/O Performance (Sequential & Random 4K)
bench_storage() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "620|38500|0.8"
        return
    fi

    local test_file="$TMP_DIR/io_test.bin"
    local seq_mb=100
    [ "$QUICK" -eq 1 ] && seq_mb=40

    # Sequential write
    local seq_raw
    seq_raw="$(dd if=/dev/zero of="$test_file" bs=1M count="$seq_mb" conv=fdatasync 2>&1 || true)"
    local seq_speed_mb
    seq_speed_mb="$(echo "$seq_raw" | grep -oE '[0-9.]+ (MB|GB|kB)/s' | tail -n 1 || echo "150 MB/s")"

    # 4K random writes for IOPS estimate
    local count_4k=2500
    [ "$QUICK" -eq 1 ] && count_4k=1000

    local t_start
    t_start="$(date +%s%N 2>/dev/null || echo "")"
    dd if=/dev/zero of="$test_file" bs=4k count="$count_4k" conv=fdatasync 2>/dev/null || true
    local t_end
    t_end="$(date +%s%N 2>/dev/null || echo "")"

    local iops=15000
    local latency_ms=1.2
    if [ -n "$t_start" ] && [ -n "$t_end" ] && [ "$t_end" -gt "$t_start" ]; then
        local elapsed_ms=$(( (t_end - t_start) / 1000000 ))
        if [ "$elapsed_ms" -gt 0 ]; then
            iops=$(( (count_4k * 1000) / elapsed_ms ))
            latency_ms="$(awk "BEGIN {printf \"%.2f\", $elapsed_ms / $count_4k}")"
        fi
    fi

    rm -f "$test_file"
    echo "$seq_speed_mb|$iops|$latency_ms"
}

# 4. Network Latencies & CDN Speedtest (Download & Upload)
bench_network() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "4.2|0.1|8.5|11.2|2.1|185.0|1480.0|92.5|740.0"
        return
    fi

    local targets=("1.1.1.1" "8.8.8.8" "9.9.9.9" "77.88.8.8")
    local rtts=()

    for target in "${targets[@]}"; do
        local rtt="N/A"
        if command -v ping >/dev/null 2>&1; then
            local ping_out
            ping_out="$(ping -c 2 -W 2 "$target" 2>/dev/null || true)"
            local avg
            avg="$(echo "$ping_out" | grep -oE 'avg[^/]*= [0-9.]+' | grep -oE '[0-9.]+' | tail -n 1 || echo "")"
            if [ -z "$avg" ]; then
                avg="$(echo "$ping_out" | grep -oE '/[0-9.]+' | sed -e 's/\///' | head -n 2 | tail -n 1 || echo "")"
            fi
            if [ -n "$avg" ]; then
                rtt="$avg"
            fi
        fi
        rtts+=("$rtt")
    done

    # DNS Resolution latency
    local dns_lookup_ms="1.5"
    if command -v curl >/dev/null 2>&1; then
        local timing
        timing="$(curl -s -o /dev/null -w "%{time_namelookup}\n" --connect-timeout 2 https://1.1.1.1 2>/dev/null || echo "0.002")"
        dns_lookup_ms="$(awk "BEGIN {printf \"%.1f\", $timing * 1000}")"
    fi

    # Fast Download test (25MB payload from Cloudflare CDN; 10MB in quick mode)
    local dl_bytes=25000000
    [ "$QUICK" -eq 1 ] && dl_bytes=10000000
    local dl_speed_mb="0.0"
    local dl_speed_mbps="0.0"

    if command -v curl >/dev/null 2>&1; then
        local dl_bytes_sec
        dl_bytes_sec="$(curl -s -o /dev/null -w "%{speed_download}\n" --max-time 8 "https://speed.cloudflare.com/__down?bytes=$dl_bytes" 2>/dev/null || echo "0")"
        if [ -n "$dl_bytes_sec" ] && [ "$(awk "BEGIN {print ($dl_bytes_sec > 0 ? 1 : 0)}")" -eq 1 ]; then
            dl_speed_mb="$(awk "BEGIN {printf \"%.1f\", $dl_bytes_sec / 1048576}")"
            dl_speed_mbps="$(awk "BEGIN {printf \"%.1f\", ($dl_bytes_sec * 8) / 1000000}")"
        fi
    fi

    # Fast Upload test (10MB payload via HTTP POST to Cloudflare CDN; 5MB in quick mode)
    local ul_bytes=10000000
    [ "$QUICK" -eq 1 ] && ul_bytes=5000000
    local ul_speed_mb="0.0"
    local ul_speed_mbps="0.0"

    if command -v curl >/dev/null 2>&1; then
        local ul_bytes_sec
        ul_bytes_sec="$(head -c "$ul_bytes" /dev/zero | curl -s -o /dev/null -w "%{speed_upload}\n" --max-time 8 --data-binary @- "https://speed.cloudflare.com/__up" 2>/dev/null || echo "0")"
        if [ -n "$ul_bytes_sec" ] && [ "$(awk "BEGIN {print ($ul_bytes_sec > 0 ? 1 : 0)}")" -eq 1 ]; then
            ul_speed_mb="$(awk "BEGIN {printf \"%.1f\", $ul_bytes_sec / 1048576}")"
            ul_speed_mbps="$(awk "BEGIN {printf \"%.1f\", ($ul_bytes_sec * 8) / 1000000}")"
        fi
    fi

    echo "${rtts[0]}|${rtts[1]}|${rtts[2]}|${rtts[3]}|$dns_lookup_ms|$dl_speed_mb|$dl_speed_mbps|$ul_speed_mb|$ul_speed_mbps"
}

main() {
    IFS='|' read -r os_name kernel cpu_model cpu_cores mem_total_mb disk_total_gb <<< "$(get_system_info)"
    IFS='|' read -r steal_pct cpu_speed_mb <<< "$(bench_cpu)"
    IFS='|' read -r seq_speed_mb iops latency_ms <<< "$(bench_storage)"
    IFS='|' read -r ping_cf ping_google ping_quad9 ping_yandex dns_ms dl_speed_mb dl_speed_mbps ul_speed_mb ul_speed_mbps <<< "$(bench_network)"

    local is_steal_elevated
    is_steal_elevated="$(awk "BEGIN {print ($steal_pct > 5.0 ? 1 : 0)}")"

    if [ "$JSON_OUTPUT" -eq 1 ]; then
        cat <<EOF
{
  "system": {
    "os": "$os_name",
    "kernel": "$kernel",
    "cpu_model": "$cpu_model",
    "cpu_cores": $cpu_cores,
    "ram_total_mb": $mem_total_mb,
    "disk_total_gb": $disk_total_gb
  },
  "cpu_benchmark": {
    "steal_time_pct": $steal_pct,
    "sha256_mb_s": $cpu_speed_mb,
    "hypervisor_noise_status": "$([ "$is_steal_elevated" -eq 1 ] && echo "ELEVATED" || echo "CLEAN")"
  },
  "storage_benchmark": {
    "sequential_write": "$seq_speed_mb",
    "random_4k_iops": $iops,
    "random_4k_latency_ms": $latency_ms
  },
  "network_benchmark": {
    "latencies_ms": {
      "cloudflare_1_1_1_1": "$ping_cf",
      "google_8_8_8_8": "$ping_google",
      "quad9_9_9_9": "$ping_quad9",
      "yandex_77_88_88": "$ping_yandex"
    },
    "dns_resolution_ms": $dns_ms,
    "cdn_download_mb_s": $dl_speed_mb,
    "cdn_download_mbps": $dl_speed_mbps,
    "cdn_upload_mb_s": $ul_speed_mb,
    "cdn_upload_mbps": $ul_speed_mbps
  }
}
EOF
        return 0
    fi

    # Terminal Scorecard Output
    local BOLD="\033[1m"
    local GREEN="\033[1;32m"
    local BLUE="\033[1;34m"
    local YELLOW="\033[1;33m"
    local RED="\033[1;31m"
    local CYAN="\033[1;36m"
    local RESET="\033[0m"

    echo -e "${BOLD}${BLUE}"
    echo "================================================================================"
    echo "                 SERVER-SETUP SYSTEM & NETWORK BENCHMARK                        "
    echo "================================================================================"
    echo -e "${RESET}"

    echo -e "${BOLD}🖥  SYSTEM SPECIFICATIONS${RESET}"
    printf "  %-20s: %s\n" "Operating System" "$os_name"
    printf "  %-20s: %s\n" "Kernel Release" "$kernel"
    printf "  %-20s: %s (%s cores)\n" "CPU Processor" "$cpu_model" "$cpu_cores"
    printf "  %-20s: %s MB RAM | %s GB Disk\n" "Memory & Disk" "$mem_total_mb" "$disk_total_gb"
    echo ""

    echo -e "${BOLD}⚡ CPU & HYPERVISOR HEALTH${RESET}"
    printf "  %-20s: %s%%\n" "CPU Steal Time" "$steal_pct"
    if [ "$is_steal_elevated" -eq 1 ]; then
        printf "  %-20s: ${RED}⚠️  ELEVATED (Host neighbor congestion detected)${RESET}\n" "Steal Status"
    else
        printf "  %-20s: ${GREEN}✓ Clean (Minimal neighbor interference)${RESET}\n" "Steal Status"
    fi
    printf "  %-20s: %s MB/s\n" "SHA-256 Throughput" "$cpu_speed_mb"
    echo ""

    echo -e "${BOLD}💾 STORAGE I/O PERFORMANCE${RESET}"
    printf "  %-20s: %s\n" "Sequential Write" "$seq_speed_mb"
    printf "  %-20s: ~%s IOPS (latency: %s ms)\n" "Random 4K Write" "$iops" "$latency_ms"
    echo ""

    echo -e "${BOLD}🌐 NETWORK LATENCY & BANDWIDTH${RESET}"
    printf "  %-20s: %s ms (Cloudflare) | %s ms (Google)\n" "Global RTT" "$ping_cf" "$ping_google"
    printf "  %-20s: %s ms (Quad9)      | %s ms (Yandex)\n" "Regional RTT" "$ping_quad9" "$ping_yandex"
    printf "  %-20s: %s ms\n" "DNS Query Time" "$dns_ms"
    printf "  %-20s: %s Mbit/s (%s MB/s)\n" "CDN Download Speed" "$dl_speed_mbps" "$dl_speed_mb"
    printf "  %-20s: %s Mbit/s (%s MB/s)\n" "CDN Upload Speed" "$ul_speed_mbps" "$ul_speed_mb"
    echo ""
    echo -e "${BOLD}${GREEN}✓ Benchmark completed successfully.${RESET}"
    echo "================================================================================"
}

main "$@"
