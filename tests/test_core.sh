#!/usr/bin/env bash
# ==============================================================================
# tests/test_core.sh - Deep Verification of Core Engine Components
# Tests: core/memory.sh, core/docker.sh, core/system.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DRY_RUN=1

echo ">>> [1/5] Checking bash syntax for all core modules..."
bash -n "$SCRIPT_DIR/core/preflight.sh"
bash -n "$SCRIPT_DIR/core/memory.sh"
bash -n "$SCRIPT_DIR/core/docker.sh"
bash -n "$SCRIPT_DIR/core/system.sh"
bash -n "$SCRIPT_DIR/core/time.sh"
echo "Core syntax checks passed ✅"

echo ">>> [2/4] Testing core/memory.sh..."
"$SCRIPT_DIR/core/memory.sh" --help >/dev/null 2>&1 || true
mem_out="$("$SCRIPT_DIR/core/memory.sh")"

# Behavioral assertions
echo "$mem_out" | grep -q "swapfile" || { echo "❌ memory.sh missing swapfile logic"; exit 1; }
echo "$mem_out" | grep -q "zram" || { echo "❌ memory.sh missing zram logic"; exit 1; }
echo "$mem_out" | grep -q "vm.swappiness=100" || { echo "❌ memory.sh missing swappiness sysctl"; exit 1; }
echo "$mem_out" | grep -q "page-cluster=0" || { echo "❌ memory.sh missing page-cluster sysctl"; exit 1; }
echo "$mem_out" | grep -q "systemd-oomd" || { echo "❌ memory.sh missing systemd-oomd disable"; exit 1; }
echo "$mem_out" | grep -q "SystemMaxUse=100M" || { echo "❌ memory.sh missing journald limit"; exit 1; }
echo "core/memory.sh assertions passed ✅"

echo ">>> [3/4] Testing core/docker.sh..."
"$SCRIPT_DIR/core/docker.sh" --help >/dev/null 2>&1 || true
docker_out="$("$SCRIPT_DIR/core/docker.sh")"

# Behavioral assertions
echo "$docker_out" | grep -q "Docker Engine" || { echo "❌ docker.sh missing engine check"; exit 1; }
echo "$docker_out" | grep -q "crun" || { echo "❌ docker.sh missing crun runtime setup"; exit 1; }
echo "$docker_out" | grep -q "userland-proxy=false" || { echo "❌ docker.sh missing daemon.json proxy config"; exit 1; }
echo "$docker_out" | grep -q "GOMEMLIMIT=128MiB" || { echo "❌ docker.sh missing GOMEMLIMIT systemd override"; exit 1; }
echo "$docker_out" | grep -q "dokploy-network" || { echo "❌ docker.sh missing bridge network"; exit 1; }
echo "core/docker.sh assertions passed ✅"

echo ">>> [4/5] Testing core/system.sh..."
"$SCRIPT_DIR/core/system.sh" --help >/dev/null
sys_out="$("$SCRIPT_DIR/core/system.sh")"

# Behavioral assertions
echo "$sys_out" | grep -q "Google BBR" || { echo "❌ system.sh missing BBR activation"; exit 1; }
echo "$sys_out" | grep -q "99-network-security.conf" || { echo "❌ system.sh missing sysctl security config"; exit 1; }
echo "$sys_out" | grep -q "DefaultLimitNOFILE=65535:1048576" || { echo "❌ system.sh missing nofile limits"; exit 1; }
echo "$sys_out" | grep -q "fs.file-max=2097152" || { echo "❌ system.sh missing file-max"; exit 1; }
echo "$sys_out" | grep -q "fstrim.timer" || { echo "❌ system.sh missing fstrim"; exit 1; }
echo "$sys_out" | grep -q "unattended-upgrades" || { echo "❌ system.sh missing unattended-upgrades"; exit 1; }
echo "core/system.sh assertions passed ✅"

echo ">>> [5/5] Testing core/time.sh..."
"$SCRIPT_DIR/core/time.sh" --help >/dev/null
time_out="$("$SCRIPT_DIR/core/time.sh")"
echo "$time_out" | grep -q "time.cloudflare.com" || { echo "❌ time.sh missing Cloudflare NTP"; exit 1; }
echo "$time_out" | grep -q "systemd-timesyncd or chrony" || { echo "❌ time.sh missing time syncd"; exit 1; }
echo "core/time.sh assertions passed ✅"

echo "✅ All Core Engine tests passed successfully with full behavioral assertions!"
