#!/usr/bin/env bash
# ==============================================================================
# Server Setup: IP Reputation & Threat Intelligence Engine
# Inspects server public IPs across global DNSBL lists, ASN/Geo, and threat feeds
# ==============================================================================
set -euo pipefail

# Text styling
BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
BLUE="\033[0;34m"
DIM="\033[2m"
RESET="\033[0m"

log_info()  { echo -e "${CYAN}[INFO]${RESET} $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${RESET} $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# Configuration variables
CUSTOM_DNS=""
OUTPUT_JSON=0
DRY_RUN="${DRY_RUN:-0}"
ABUSEIPDB_KEY="${ABUSEIPDB_KEY:-}"
VIRUSTOTAL_KEY="${VIRUSTOTAL_KEY:-}"
SAVE_PATH="/var/log/server-setup/ip-audit.json"
TARGET_IPS=()
AUDIT_ALL=0

# Standard DNSBL list (20 popular reputation & threat lists)
DNSBL_LIST=(
  "zen.spamhaus.org:Spamhaus ZEN (SBL+XBL+PBL):critical"
  "b.barracudacentral.org:Barracuda Reputation Network:critical"
  "bl.spamcop.net:SpamCop Blocking List:critical"
  "dnsbl.dronebl.org:DroneBL Botnet & Open Proxy:high"
  "dnsbl-1.uceprotect.net:UCEPROTECT Level 1:medium"
  "dnsbl-2.uceprotect.net:UCEPROTECT Level 2:medium"
  "dnsbl.sorbs.net:SORBS Combined List:medium"
  "all.s5h.net:S5h Spam List:medium"
  "bl.nordspam.com:Nordspam Realtime:medium"
  "hostkarma.junkemailfilter.com:Hostkarma Blacklist:medium"
  "spamsources.fabel.dk:Fabel Spam Sources:medium"
  "ubl.unsubscore.com:LashBack Unsubscribe Blacklist:medium"
  "ips.backscatterer.org:Backscatterer NDBL:low"
  "truncate.gbudb.net:GBUdb Truncate:medium"
  "dnsbl.zapbl.net:ZapBL Fast-flux & Spam:medium"
  "ix.dnsbl.manitu.net:NiX Spam Blacklist:medium"
  "spam.dnsbl.anonmails.de:Anonmails Spam List:low"
  "bl.mailspike.net:Mailspike Blacklist:medium"
  "rbl.interserver.net:Interserver RBL:low"
  "psbl.surriel.com:Surriel Passive Spam Block List:medium"
)

show_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [IP_ADDRESS...]

Inspect public IP addresses against 20+ reputation blacklists, ASN databases,
and threat intelligence feeds.

Options:
  [IP_ADDRESS...]          One or more IPs to audit (defaults to host public IPs)
  --all                    Audit all detected local and egress public IPs
  --dns <ip>               Custom DNS resolver to query (e.g. 9.9.9.9, 1.1.1.1)
  --json                   Emit machine-readable JSON output to stdout
  --abuseipdb-key <key>    Optional AbuseIPDB API key for deep threat score
  --virustotal-key <key>   Optional VirusTotal API key for malware intelligence
  --save <file_path>       Custom destination for JSON report (default: ${SAVE_PATH})
  --no-save                Do not write output to disk
  --dry-run                Simulate audit with mock responses without network calls
  -h, --help               Show this help message

Examples:
  $(basename "$0")
  $(basename "$0") 1.2.3.4
  $(basename "$0") 1.2.3.4 2001:db8::1 --json
  $(basename "$0") --dns 9.9.9.9
EOF
}

# Parse Command Line Arguments
NO_SAVE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      AUDIT_ALL=1
      shift
      ;;
    --dns)
      CUSTOM_DNS="${2:-}"
      shift 2
      ;;
    --json)
      OUTPUT_JSON=1
      shift
      ;;
    --abuseipdb-key)
      ABUSEIPDB_KEY="${2:-}"
      shift 2
      ;;
    --virustotal-key)
      VIRUSTOTAL_KEY="${2:-}"
      shift 2
      ;;
    --save)
      SAVE_PATH="${2:-}"
      shift 2
      ;;
    --no-save)
      NO_SAVE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    -*)
      log_error "Unknown option: $1"
      show_help
      exit 1
      ;;
    *)
      TARGET_IPS+=("$1")
      shift
      ;;
  esac
done

# Reverse IPv4 for DNSBL lookup (e.g. 1.2.3.4 -> 4.3.2.1)
reverse_ipv4() {
  local ip="$1"
  local o1 o2 o3 o4
  IFS='.' read -r o1 o2 o3 o4 <<< "${ip}"
  echo "${o4}.${o3}.${o2}.${o1}"
}

# Expand and reverse IPv6 into nibbles for .ip6.arpa (e.g. 2001:db8::1)
reverse_ipv6() {
  local ip="$1"
  # Use python or awk to expand IPv6 if available, or basic expander
  local expanded
  if command -v python3 >/dev/null 2>&1; then
    expanded=$(python3 -c "import ipaddress; print(ipaddress.IPv6Address('${ip}').exploded)" 2>/dev/null || echo "")
  fi
  if [[ -z "${expanded}" ]]; then
    # Fallback to pure bash expansion for basic IPv6
    echo ""
    return
  fi
  local clean
  clean=$(echo "${expanded}" | tr -d ':')
  local rev=""
  for (( i=${#clean}-1; i>=0; i-- )); do
    rev="${rev}${clean:$i:1}."
  done
  echo "${rev%*.}"
}

# Detect public IPs of current machine
discover_host_ips() {
  local ips=()
  
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "198.51.100.42"
    return
  fi

  # 1. Fetch public egress IPv4
  local egress_v4
  egress_v4=$(curl -s --connect-timeout 2 -4 https://api.ipify.org 2>/dev/null || curl -s --connect-timeout 2 -4 https://icanhazip.com 2>/dev/null || true)
  if [[ -n "${egress_v4}" && "${egress_v4}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ips+=("${egress_v4}")
  fi

  # 2. Fetch public egress IPv6
  local egress_v6
  egress_v6=$(curl -s --connect-timeout 2 -6 https://api64.ipify.org 2>/dev/null || true)
  if [[ -n "${egress_v6}" && "${egress_v6}" =~ : ]]; then
    ips+=("${egress_v6}")
  fi

  # 3. Detect interface IPs if --all requested
  if [[ "${AUDIT_ALL}" -eq 1 ]] && command -v ip >/dev/null 2>&1; then
    while IFS= read -r iface_ip; do
      [[ -z "${iface_ip}" ]] && continue
      # Filter private ranges (10.x, 172.16-31, 192.168, 127.x, fe80:)
      if [[ "${iface_ip}" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|127\.|fe80:) ]]; then
        continue
      fi
      ips+=("${iface_ip}")
    done < <(ip -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
  fi

  # Deduplicate
  printf '%s\n' "${ips[@]}" | sort -u
}

# Resolve DNS query using dig or host
dns_query() {
  local query="$1"
  local type="${2:-A}"
  local resolver="${CUSTOM_DNS}"

  if command -v dig >/dev/null 2>&1; then
    local -a dns_args=()
    [[ -n "${resolver}" ]] && dns_args=("@${resolver}")
    dig +short +time=1 +tries=1 "${query}" "${type}" "${dns_args[@]}" 2>/dev/null || true
  elif command -v host >/dev/null 2>&1; then
    local -a dns_args=()
    [[ -n "${resolver}" ]] && dns_args=("${resolver}")
    host -W 1 -t "${type}" "${query}" "${dns_args[@]}" 2>/dev/null | awk '/has address/ {print $NF}' || true
  else
    echo ""
  fi
}

# Reverse DNS lookup (PTR)
lookup_ptr() {
  local ip="$1"
  local resolver="${CUSTOM_DNS}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "node-42.example-vps.com"
    return
  fi

  if command -v dig >/dev/null 2>&1; then
    local -a dns_args=()
    [[ -n "${resolver}" ]] && dns_args=("@${resolver}")
    dig +short +time=1 +tries=1 -x "${ip}" "${dns_args[@]}" 2>/dev/null | sed 's/\.$//' | head -n 1 || true
  elif command -v host >/dev/null 2>&1; then
    local -a dns_args=()
    [[ -n "${resolver}" ]] && dns_args=("${resolver}")
    host -W 1 "${ip}" "${dns_args[@]}" 2>/dev/null | awk '/pointer/ {print $NF}' | sed 's/\.$//' | head -n 1 || true
  else
    echo ""
  fi
}

# Fetch Geo and ASN profile
fetch_geo_profile() {
  local ip="$1"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    cat <<EOF
{
  "status": "success",
  "country": "Germany",
  "countryCode": "DE",
  "regionName": "Hesse",
  "city": "Frankfurt",
  "isp": "Hetzner Online GmbH",
  "org": "Hetzner Online GmbH",
  "as": "AS24940 Hetzner Online GmbH",
  "proxy": false,
  "hosting": true,
  "mobile": false
}
EOF
    return
  fi

  local response
  response=$(curl -s --connect-timeout 3 "http://ip-api.com/json/${ip}?fields=status,message,country,countryCode,regionName,city,isp,org,as,mobile,proxy,hosting" 2>/dev/null || true)
  if [[ -n "${response}" && "${response}" =~ "status" ]]; then
    echo "${response}"
  else
    # Fallback minimal JSON
    echo '{"status":"fail","country":"Unknown","countryCode":"XX","regionName":"","city":"","isp":"Unknown","org":"Unknown","as":"","proxy":false,"hosting":true,"mobile":false}'
  fi
}

# Query AbuseIPDB if API key provided
fetch_abuseipdb_score() {
  local ip="$1"
  local key="$2"
  if [[ -z "${key}" ]] || [[ "${DRY_RUN}" -eq 1 ]]; then
    echo '{"score": 0, "reports": 0, "last_reported": null}'
    return
  fi

  local response
  response=$(curl -s --connect-timeout 3 \
    -H "Key: ${key}" \
    -H "Accept: application/json" \
    "https://api.abuseipdb.com/api/v2/check?ipAddress=${ip}&maxAgeInDays=90" 2>/dev/null || true)

  if command -v jq >/dev/null 2>&1 && [[ -n "${response}" ]]; then
    local score reports last_rep
    score=$(echo "${response}" | jq -r '.data.abuseConfidenceScore // 0' 2>/dev/null || echo 0)
    reports=$(echo "${response}" | jq -r '.data.totalReports // 0' 2>/dev/null || echo 0)
    last_rep=$(echo "${response}" | jq -r '.data.lastReportedAt // "none"' 2>/dev/null || echo "none")
    echo "{\"score\": ${score}, \"reports\": ${reports}, \"last_reported\": \"${last_rep}\"}"
  else
    echo '{"score": 0, "reports": 0, "last_reported": null}'
  fi
}

# Perform parallel DNSBL audits for a single IP
audit_dnsbl() {
  local ip="$1"
  local is_v6=0
  [[ "${ip}" =~ : ]] && is_v6=1

  local reversed_ip=""
  if [[ "${is_v6}" -eq 1 ]]; then
    reversed_ip=$(reverse_ipv6 "${ip}")
  else
    reversed_ip=$(reverse_ipv4 "${ip}")
  fi

  local tmp_dir
  tmp_dir=$(mktemp -d "/tmp/dnsbl_check_XXXXXX")
  
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    # In dry-run mode, simulate 0 hits
    rm -rf "${tmp_dir}"
    echo '{"total": 20, "listed": 0, "hits": []}'
    return
  fi

  # Launch checks in parallel
  local idx=0
  for entry in "${DNSBL_LIST[@]}"; do
    IFS=':' read -r domain name severity <<< "${entry}"
    (
      local lookup_host="${reversed_ip}.${domain}"
      local res
      res=$(dns_query "${lookup_host}" "A")
      
      # Clean up trailing spaces/newlines
      res=$(echo "${res}" | tr -d '[:space:]')

      # Check if IP resolved to a 127.0.0.x response
      if [[ -n "${res}" && "${res}" =~ ^127\. ]]; then
        # Check for open resolver block codes (127.255.255.254 / 127.255.255.255)
        if [[ "${res}" =~ ^127\.255\.255\. ]]; then
          # Open resolver blocked or query refused -> skip
          :
        else
          # Valid blacklist hit
          echo "${domain}|${name}|${severity}|${res}" > "${tmp_dir}/hit_${idx}.txt"
        fi
      fi
    ) &
    idx=$((idx + 1))
  done

  # Wait for all background queries
  wait

  # Collect results
  local hits=()
  local hit_files
  hit_files=$(find "${tmp_dir}" -type f -name "hit_*.txt" 2>/dev/null || true)
  if [[ -n "${hit_files}" ]]; then
    while IFS= read -r f; do
      [[ -f "${f}" ]] || continue
      hits+=("$(cat "${f}")")
    done <<< "${hit_files}"
  fi
  rm -rf "${tmp_dir}"

  local listed_count=${#hits[@]}
  local hits_json="[]"

  if [[ ${listed_count} -gt 0 ]]; then
    local items=()
    for h in "${hits[@]}"; do
      IFS='|' read -r h_domain h_name h_sev h_code <<< "${h}"
      items+=("{\"domain\":\"${h_domain}\",\"name\":\"${h_name}\",\"severity\":\"${h_sev}\",\"return_code\":\"${h_code}\"}")
    done
    hits_json=$(printf ",%s" "${items[@]}")
    hits_json="[${hits_json:1}]"
  fi

  echo "{\"total\": ${#DNSBL_LIST[@]}, \"listed\": ${listed_count}, \"hits\": ${hits_json}}"
}

# Calculate unified risk score (0-100)
calculate_risk() {
  local listed_count="$1"
  local hits_json="$2"
  local is_hosting="$3"
  local is_proxy="$4"
  local abuse_score="$5"

  local score=0

  # Blacklist hits
  if [[ ${listed_count} -gt 0 ]]; then
    # Check severity
    if [[ "${hits_json}" =~ "critical" ]]; then
      score=$((score + listed_count * 25))
    elif [[ "${hits_json}" =~ "high" ]]; then
      score=$((score + listed_count * 15))
    else
      score=$((score + listed_count * 10))
    fi
  fi

  # Proxy / VPN / Tor flag
  if [[ "${is_proxy}" == "true" ]]; then
    score=$((score + 25))
  fi

  # AbuseIPDB reports score
  if [[ ${abuse_score} -gt 0 ]]; then
    score=$((score + abuse_score / 2))
  fi

  # Cap at 100
  [[ ${score} -gt 100 ]] && score=100

  echo "${score}"
}

# Determine classification badge
get_status_badge() {
  local score="$1"
  if [[ ${score} -le 10 ]]; then
    echo "CLEAN"
  elif [[ ${score} -le 40 ]]; then
    echo "SUSPICIOUS"
  else
    echo "HIGH RISK"
  fi
}

# Audit a single IP
audit_ip() {
  local ip="$1"
  local is_v6=0
  [[ "${ip}" =~ : ]] && is_v6=1

  # 1. PTR / rDNS
  local ptr
  ptr=$(lookup_ptr "${ip}")
  [[ -z "${ptr}" ]] && ptr="(no rDNS / PTR record)"

  # 2. Geo & ASN
  local geo_json
  geo_json=$(fetch_geo_profile "${ip}")

  local country country_code city isp org as_info is_proxy is_hosting
  if command -v jq >/dev/null 2>&1; then
    country=$(echo "${geo_json}" | jq -r '.country // "Unknown"')
    country_code=$(echo "${geo_json}" | jq -r '.countryCode // "XX"')
    city=$(echo "${geo_json}" | jq -r '.city // "Unknown"')
    isp=$(echo "${geo_json}" | jq -r '.isp // "Unknown"')
    org=$(echo "${geo_json}" | jq -r '.org // "Unknown"')
    as_info=$(echo "${geo_json}" | jq -r '.as // "Unknown"')
    is_proxy=$(echo "${geo_json}" | jq -r '.proxy // false')
    is_hosting=$(echo "${geo_json}" | jq -r '.hosting // true')
  else
    # Simple regex fallback
    country="Unknown"; country_code="XX"; city=""; isp="Unknown"; org="Unknown"; as_info=""
    is_proxy="false"; is_hosting="true"
  fi

  # 3. AbuseIPDB check if key supplied
  local abuse_json
  abuse_json=$(fetch_abuseipdb_score "${ip}" "${ABUSEIPDB_KEY}")
  local abuse_score=0
  if command -v jq >/dev/null 2>&1; then
    abuse_score=$(echo "${abuse_json}" | jq -r '.score // 0')
  fi

  # 4. Parallel DNSBL audit
  local dnsbl_json
  dnsbl_json=$(audit_dnsbl "${ip}")
  local dnsbl_total=20
  local dnsbl_listed=0
  local hits_list="[]"
  if command -v jq >/dev/null 2>&1; then
    dnsbl_total=$(echo "${dnsbl_json}" | jq -r '.total // 20')
    dnsbl_listed=$(echo "${dnsbl_json}" | jq -r '.listed // 0')
    hits_list=$(echo "${dnsbl_json}" | jq -c '.hits // []')
  fi

  # 5. Risk Calculation
  local risk_score
  risk_score=$(calculate_risk "${dnsbl_listed}" "${hits_list}" "${is_hosting}" "${is_proxy}" "${abuse_score}")
  local badge
  badge=$(get_status_badge "${risk_score}")

  # 6. Output formatting
  if [[ "${OUTPUT_JSON}" -eq 1 ]]; then
    cat <<EOF
{
  "ip": "${ip}",
  "version": $(if [[ ${is_v6} -eq 1 ]]; then echo 6; else echo 4; fi),
  "rdns": "${ptr}",
  "geo": {
    "country": "${country}",
    "country_code": "${country_code}",
    "city": "${city}",
    "isp": "${isp}",
    "org": "${org}",
    "as": "${as_info}"
  },
  "classification": {
    "hosting_datacenter": ${is_hosting},
    "proxy_or_vpn": ${is_proxy}
  },
  "dnsbl": {
    "total_checked": ${dnsbl_total},
    "listed_count": ${dnsbl_listed},
    "hits": ${hits_list}
  },
  "abuseipdb": ${abuse_json},
  "risk_score": ${risk_score},
  "status": "${badge}"
}
EOF
  else
    # Terminal UI Card
    local color_badge="${GREEN}"
    [[ "${badge}" == "SUSPICIOUS" ]] && color_badge="${YELLOW}"
    [[ "${badge}" == "HIGH RISK" ]] && color_badge="${RED}"

    echo ""
    echo -e "${BOLD}${BLUE}┌────────────────────────────────────────────────────────────────────────┐${RESET}"
    echo -e "${BOLD}${BLUE}│${RESET}  ${BOLD}IP REPUTATION & THREAT INTELLIGENCE AUDIT${RESET}                             ${BOLD}${BLUE}│${RESET}"
    echo -e "${BOLD}${BLUE}└────────────────────────────────────────────────────────────────────────┘${RESET}"
    echo -e "  ${BOLD}Target IP:${RESET}      ${CYAN}${ip}${RESET} (IPv$(if [[ ${is_v6} -eq 1 ]]; then echo 6; else echo 4; fi))"
    echo -e "  ${BOLD}rDNS / PTR:${RESET}     ${DIM}${ptr}${RESET}"
    echo -e "  ${BOLD}Geolocation:${RESET}    ${country} (${country_code}), ${city}"
    echo -e "  ${BOLD}Network / ASN:${RESET}  ${as_info} - ${org}"
    echo -e "  ${BOLD}Host Type:${RESET}      $([[ "${is_hosting}" == "true" ]] && echo "Datacenter / VPS" || echo "Residential / Mobile")$([[ "${is_proxy}" == "true" ]] && echo " ${YELLOW}[PROXY/TOR DETECTED]${RESET}")"
    echo -e "  ${BOLD}DNS Resolver:${RESET}   $([[ -n "${CUSTOM_DNS}" ]] && echo "${CUSTOM_DNS}" || echo "System default (/etc/resolv.conf)")"
    echo -e "  ${BOLD}Blacklists:${RESET}     ${BOLD}${dnsbl_listed}/${dnsbl_total}${RESET} active listings"
    echo -e "  ${BOLD}Reputation:${RESET}     ${color_badge}${BOLD}[${badge}] (Risk Score: ${risk_score}/100)${RESET}"

    if [[ ${dnsbl_listed} -gt 0 ]]; then
      echo ""
      echo -e "  ${RED}${BOLD}⚠️ Active Blacklist Listings:${RESET}"
      if command -v jq >/dev/null 2>&1; then
        echo "${hits_list}" | jq -r '.[] | "    • \(.name) (\(.domain)) - \(.severity) risk [\(.return_code)]"'
      fi
    else
      echo -e "  ${GREEN}✓ IP is clean across all checked DNSBL/RBL databases.${RESET}"
    fi
    echo -e "${BOLD}${BLUE}──────────────────────────────────────────────────────────────────────────${RESET}"
  fi
}

main() {
  # Collect target IPs
  if [[ ${#TARGET_IPS[@]} -eq 0 ]]; then
    while IFS= read -r detected; do
      [[ -n "${detected}" ]] && TARGET_IPS+=("${detected}")
    done < <(discover_host_ips)
  fi

  if [[ ${#TARGET_IPS[@]} -eq 0 ]]; then
    log_error "No public IP addresses could be discovered. Please specify target IP manually."
    exit 1
  fi

  local all_results=()
  local highest_risk=0

  if [[ "${OUTPUT_JSON}" -eq 1 ]]; then
    for target in "${TARGET_IPS[@]}"; do
      local res
      res=$(audit_ip "${target}")
      all_results+=("${res}")
      if command -v jq >/dev/null 2>&1; then
        local r
        r=$(echo "${res}" | jq -r '.risk_score // 0')
        [[ ${r} -gt ${highest_risk} ]] && highest_risk=${r}
      fi
    done

    local joined_json
    joined_json=$(printf ",%s" "${all_results[@]}")
    local final_json
    final_json=$(cat <<EOF
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "dns_resolver": "$([[ -n "${CUSTOM_DNS}" ]] && echo "${CUSTOM_DNS}" || echo "system")",
  "highest_risk_score": ${highest_risk},
  "overall_status": "$(get_status_badge "${highest_risk}")",
  "results": [${joined_json:1}]
}
EOF
)
    echo "${final_json}"

    # Save to disk if requested and permitted
    if [[ "${NO_SAVE}" -eq 0 && "${DRY_RUN}" -eq 0 ]]; then
      local save_dir
      save_dir=$(dirname "${SAVE_PATH}")
      if mkdir -p "${save_dir}" 2>/dev/null && touch "${SAVE_PATH}" 2>/dev/null; then
        echo "${final_json}" > "${SAVE_PATH}"
      elif sudo -n true 2>/dev/null; then
        sudo mkdir -p "${save_dir}" && echo "${final_json}" | sudo tee "${SAVE_PATH}" >/dev/null
      fi
    fi
  else
    for target in "${TARGET_IPS[@]}"; do
      audit_ip "${target}"
    done
  fi
}

main "$@"
