#!/usr/bin/env bash
# ==============================================================================
# test_security.sh - Automated Unit & Integration Tests for Security Modules
# Tests: core/system.sh, ssh.sh, firewall.sh, ids.sh, and setup.sh --secure flag
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo ">>> [1/7] Syntax checks for security scripts..."
bash -n "$PROJECT_ROOT/core/system.sh"
bash -n "$PROJECT_ROOT/modules/security/ssh.sh"
bash -n "$PROJECT_ROOT/modules/security/firewall.sh"
bash -n "$PROJECT_ROOT/modules/security/ids.sh"
echo "Syntax checks passed ✅"

echo ">>> [2/7] Testing core/system.sh in dry-run mode..."
sys_out=$(DRY_RUN=1 "$PROJECT_ROOT/core/system.sh")
echo "$sys_out" | grep -q "Google BBR" || { echo "❌ Missing BBR configuration"; exit 1; }
echo "$sys_out" | grep -q "99-network-security.conf" || { echo "❌ Missing network security sysctl"; exit 1; }
echo "$sys_out" | grep -q "DefaultLimitNOFILE" || { echo "❌ Missing systemd limits"; exit 1; }
echo "$sys_out" | grep -q "fstrim.timer" || { echo "❌ Missing fstrim"; exit 1; }
echo "$sys_out" | grep -q "unattended-upgrades" || { echo "❌ Missing unattended-upgrades"; exit 1; }
echo "core/system.sh dry-run passed ✅"

echo ">>> [3/7] Testing modules/security/ssh.sh in dry-run mode..."
"$PROJECT_ROOT/modules/security/ssh.sh" --help >/dev/null
ssh_out_default=$(DRY_RUN=1 "$PROJECT_ROOT/modules/security/ssh.sh")
echo "$ssh_out_default" | grep -q "99-hardened.conf" || { echo "❌ Missing ssh drop-in config"; exit 1; }
echo "$ssh_out_default" | grep -q "sshd -t" || { echo "❌ Missing sshd -t syntax test"; exit 1; }

# Custom port
ssh_out_port=$(DRY_RUN=1 "$PROJECT_ROOT/modules/security/ssh.sh" --port 2222)
echo "$ssh_out_port" | grep -q "Port 2222" || { echo "❌ Custom SSH port 2222 not configured"; exit 1; }
echo "modules/security/ssh.sh dry-run passed ✅"

echo ">>> [4/7] Testing modules/security/firewall.sh in dry-run mode..."
"$PROJECT_ROOT/modules/security/firewall.sh" --help >/dev/null
fw_out=$(DRY_RUN=1 "$PROJECT_ROOT/modules/security/firewall.sh" --ssh-port 2222 --open-ports 80,443)
echo "$fw_out" | grep -q "ufw package" || { echo "❌ Missing ufw install check"; exit 1; }
echo "$fw_out" | grep -q "DOCKER-USER" || { echo "❌ Missing DOCKER-USER chain"; exit 1; }
echo "$fw_out" | grep -q "SSH port 2222/tcp" || { echo "❌ Missing custom SSH port in firewall"; exit 1; }
echo "$fw_out" | grep -q "80,443" || { echo "❌ Missing extra ports in firewall"; exit 1; }
echo "$fw_out" | grep -q "default deny incoming" || { echo "❌ Missing default deny"; exit 1; }
echo "modules/security/firewall.sh dry-run passed ✅"

echo ">>> [5/7] Testing modules/security/ids.sh in dry-run modes..."
"$PROJECT_ROOT/modules/security/ids.sh" --help >/dev/null

ids_auto=$(DRY_RUN=1 "$PROJECT_ROOT/modules/security/ids.sh" --mode auto)
echo "$ids_auto" | grep -q "Selected IDS engine" || { echo "❌ Auto detection failed"; exit 1; }

ids_f2b=$(DRY_RUN=1 "$PROJECT_ROOT/modules/security/ids.sh" --mode fail2ban)
echo "$ids_f2b" | grep -q "Fail2ban" || { echo "❌ Fail2ban mode failed"; exit 1; }
echo "$ids_f2b" | grep -q "ssh-hardened.local" || { echo "❌ Missing fail2ban jail"; exit 1; }

ids_cs=$(DRY_RUN=1 "$PROJECT_ROOT/modules/security/ids.sh" --mode crowdsec)
echo "$ids_cs" | grep -q "CrowdSec" || { echo "❌ CrowdSec mode failed"; exit 1; }
echo "$ids_cs" | grep -q "firewall bouncer" || { echo "❌ Missing CrowdSec bouncer"; exit 1; }
echo "modules/security/ids.sh dry-run passed ✅"

echo ">>> [6/7] Testing setup.sh with --secure meta-flag in dry-run..."
setup_secure_out=$("$PROJECT_ROOT/setup.sh" --dry-run --secure --ssh-port 2022 --open-ports 8080)
echo "$setup_secure_out" | grep -q "full secure profile" || { echo "❌ setup.sh missing secure profile header"; exit 1; }
echo "$setup_secure_out" | grep -q "Google BBR" || { echo "❌ setup.sh missing core system tuning"; exit 1; }
echo "$setup_secure_out" | grep -q "SSH Security Hardening" || { echo "❌ setup.sh missing SSH hardening"; exit 1; }
echo "$setup_secure_out" | grep -q "Baseline Firewall" || { echo "❌ setup.sh missing firewall"; exit 1; }
echo "$setup_secure_out" | grep -q "Intrusion Prevention" || { echo "❌ setup.sh missing IDS"; exit 1; }
echo "setup.sh --secure integration passed ✅"

echo ">>> [7/7] Testing standalone bundle with --secure flag..."
bundle_out=$("$PROJECT_ROOT/dist/server-setup-standalone.sh" --dry-run --secure)
echo "$bundle_out" | grep -q "full secure profile" || { echo "❌ standalone bundle failed --secure"; exit 1; }
echo "$bundle_out" | grep -q "All provisioning and configuration steps completed" || { echo "❌ standalone bundle execution incomplete"; exit 1; }
echo "standalone bundle --secure test passed ✅"

echo "🎉 All Security & Hardening automated tests passed successfully!"
