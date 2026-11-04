# Server Setup 🚀

> **Modular Linux & Docker Node Provisioning Toolkit with Control Plane Auto-Enrollment.**  
> Turn budget VPS instances (<= 1 GB RAM, 1 vCPU) into lean, robust Docker worker nodes consuming only **~90–110 MB idle RAM**.

[English](README.md) | [Русский](README.ru.md) | [Agent & LLM Guide](AGENTS.md)

---

## 💡 The Problem

Modern self-hosted PaaS panels (like **Dokploy**, **Coolify**, and others) are great, but their default remote node setup is often heavyweight:
- Automatically initializes **Docker Swarm mode** (raft consensus, swarm overlay).
- Runs an in-node **Traefik Ingress** container (consuming 60–100 MB RAM).
- Installs multi-gigabyte build tools (Nixpacks, Buildpacks, Railpack).
- Deploys continuous monitoring scrapers (Vector, cAdvisor, Node Exporter).

On budget cloud VPS servers ($3–$5/month with 512 MB – 1 GB RAM), this default stack consumes **450–550 MB RAM** just idling. Pulling a multi-layer container image (`docker pull`) on a single vCPU causes catastrophic **OOM (Out-of-Memory)** crashes.

## 🎯 The Solution

**`server-setup`** provides a zero-dependency, production-tested toolkit to:
1. **Slash Idle Memory by 80%**: Run Docker with `crun` and optimized `daemon.json`, keeping total OS + Docker idle footprint under **~100 MB RAM**.
2. **Eliminate OOM Crashes**: Tiered memory protection with in-memory **ZRAM (LZ4)** and fallback SSD swapfile.
3. **One-Command Auto-Enrollment (`Agent Join`)**: Run one command on the new server. It optimizes the machine, pulls your panel's SSH public key, adds it to `authorized_keys`, and registers the server into Dokploy or Coolify via API with **zero manual clicks in the UI**.
4. **Pluggable Architecture**:
   - **`core/`**: Memory & Docker low-RAM optimization.
   - **`adapters/`**: Dokploy, Coolify, Portainer, and Standalone.
   - **`modules/`**: Cloudflare Tunnel, Caddy micro-proxy, Docker Auto-Prune, and Zero-Overhead Telemetry.
5. **100% Upstream Compatible**: Requires **0 changes or patches** to Dokploy or Coolify. Works with official upstream releases.

---

## 📊 Memory Footprint Comparison

| Component | Default Node | With `server-setup` | Savings |
| :--- | :--- | :--- | :--- |
| **Linux OS Baseline** | ~70 MB | ~50 MB | Caps journald, cleans services |
| **`dockerd`** | ~90 MB | **~40 MB** | BuildKit off, `GOMEMLIMIT=128MiB` |
| **`containerd`** | ~45 MB | **~18 MB** | CRI disabled, tuned GC |
| **`docker-proxy`** | ~10 MB / port | **0 MB** | Native kernel iptables/nftables |
| **Container Shims** | ~20 MB / container (`runc`) | **2–4 MB** (`crun`) | C-based OCI runtime |
| **Docker Swarm Mode** | ~75 MB | **0 MB** | Standalone Compose mode |
| **Traefik Ingress** | ~80 MB | **0 MB** | External routing / Direct ports |
| **Vector / cAdvisor** | ~100 MB | **0 MB** | Lightweight SSH polling |
| **TOTAL Idle RAM** | **~450–550 MB** | **~90–110 MB** | **🔥 ~400+ MB freed for your apps!** |

---

## ⚡ Quick Start

### 1. Auto-Join to Dokploy (Reverse Registration)

Log in to your target server via SSH and run:

```bash
curl -sSL https://raw.githubusercontent.com/littfed/server-setup/main/dist/server-setup-standalone.sh | sudo bash -s -- \
  --panel dokploy \
  --panel-url https://dokploy.example.com \
  --api-key dkp_your_api_key_here \
  --name "worker-node-01" \
  --auto-prune
```

What happens automatically:
1. Tunes kernel memory, sets up ZRAM (LZ4) + swapfile, installs Docker with `crun`.
2. Connects to Dokploy API (`/api/sshKey.all`) and fetches your Dokploy instance's public SSH key.
3. Authorizes the key in `~/.ssh/authorized_keys` with mode 600.
4. Auto-detects public IP and calls `POST /api/server.create` and `POST /api/server.setup`.
5. **The node instantly appears active and green in your Dokploy dashboard!**

---

### 2. Auto-Join to Coolify

```bash
curl -sSL https://raw.githubusercontent.com/littfed/server-setup/main/dist/server-setup-standalone.sh | sudo bash -s -- \
  --panel coolify \
  --panel-url https://coolify.example.com \
  --api-key your_coolify_token_here \
  --name "cool-worker-01" \
  --auto-prune
```

---

### 3. Standalone Low-RAM Server with Cloudflare Tunnel & Auto-Prune

If you want to prepare any Linux VPS to run Docker with minimal memory consumption, automatic zero-port tunnel ingress, and weekly disk cleanup:

```bash
curl -sSL https://raw.githubusercontent.com/littfed/server-setup/main/dist/server-setup-standalone.sh | sudo bash -s -- \
  --panel standalone \
  --ingress cloudflare \
  --cf-token eyJxxxxxxxxxxxxxxxxxx \
  --auto-prune \
  --telemetry webhook \
  --webhook-url https://alert.example.com/webhook
```

---

### 4. IP Reputation & Threat Audit (Zero-Key)

Audit your server's public IPv4/IPv6 across 20+ reputation blacklists (Spamhaus, Barracuda, SpamCop, etc.), check ASN/ISP data, and verify rDNS/PTR:

```bash
# Standalone run on any machine (checks own public IP)
curl -sSL https://raw.githubusercontent.com/littfed/server-setup/main/dist/server-setup-standalone.sh | bash -s -- --audit-only

# Or audit an arbitrary external IP:
./modules/audit/ip-reputation.sh 1.2.3.4 --dns 9.9.9.9

# Run as pre-flight check before server enrollment (warns if dirty, or aborts with --strict-audit):
curl -sSL https://raw.githubusercontent.com/littfed/server-setup/main/dist/server-setup-standalone.sh | sudo bash -s -- \
  --panel dokploy \
  --panel-url https://dokploy.example.com \
  --api-key dkp_your_api_key_here \
  --audit-ip \
  --strict-audit
```

---

## 🛠 Command-Line Reference

```
Core Options:
  --panel <type>         Control plane: dokploy | coolify | standalone (default: standalone)
  --panel-url <url>      URL of the control plane (e.g. https://dokploy.example.com)
  --api-key <key>        API Key or Token for panel authentication
  --name <name>          Server display name (default: current hostname)
  --port <port>          SSH port of this machine (default: 22)
  --user <user>          SSH username for panel connection (default: current user)

Audit & Reputation Options:
  --audit-ip             Run IP reputation & blacklist audit on host public IPs
  --strict-audit         Abort setup if host IP has high risk or is blacklisted
  --audit-only           Run only IP reputation audit without system or Docker changes
  --dns <ip>             Custom DNS resolver for DNSBL queries (e.g. 9.9.9.9, 1.1.1.1)

Ingress Options:
  --ingress <type>       Ingress provider: none | cloudflare | caddy (default: none)
  --cf-token <token>     Cloudflare Tunnel token (required for --ingress cloudflare)
  --domain <domain>      Public domain name (used for --ingress caddy)
  --upstream <host:port> Upstream destination (default: 127.0.0.1:3000)

Maintenance Options:
  --auto-prune           Enable weekly safe Docker prune (default: enabled)
  --no-auto-prune        Disable Docker auto-prune
  --prune-age <age>      Age threshold for prune (default: 168h / 7 days)

Telemetry Options:
  --telemetry <type>     Telemetry mode: none | webhook | telegram (default: none)
  --webhook-url <url>    Webhook endpoint for JSON metrics and alerts
  --tg-token <token>     Telegram Bot token for alerts
  --tg-chat <chat_id>    Telegram Chat ID for alerts

General:
  --dry-run              Simulate execution without modifying the host
  -h, --help             Show help message
```

---

## 📂 Repository Structure

```
server-setup/
├── setup.sh                       # Unified CLI dispatcher
├── bundle.sh                      # Generates standalone self-extracting installer
├── core/
│   ├── memory.sh                  # ZRAM, swapfile, sysctl tuning
│   └── docker.sh                  # Docker Engine, crun runtime, daemon.json
├── adapters/
│   ├── dokploy.sh                 # Dokploy auto-enrollment adapter
│   ├── coolify.sh                 # Coolify auto-enrollment adapter
│   └── standalone.sh              # Headless standalone node adapter
├── modules/
│   ├── audit/
│   │   └── ip-reputation.sh       # Zero-key IP reputation & threat intelligence audit
│   ├── ingress/
│   │   ├── cloudflare.sh          # Cloudflare Tunnel (zero open ports)
│   │   └── caddy.sh               # Caddy micro-proxy (<20 MB RAM, auto-SSL)
│   ├── maintenance/
│   │   └── auto-prune.sh          # Low-priority systemd timer for image cleanup
│   └── telemetry/
│       └── health-cron.sh         # 0 MB resident RAM metrics reporter
├── dist/
│   └── server-setup-standalone.sh # Standalone single-file bundle
├── tests/
│   ├── run_all_tests.sh           # Test suite runner
│   ├── test_core.sh
│   ├── test_dokploy_adapter.sh
│   ├── test_coolify_adapter.sh
│   ├── test_auto_prune.sh
│   ├── test_ingress.sh
│   ├── test_telemetry.sh
│   └── test_cli.sh
├── .github/workflows/
│   └── ci.yml                     # Multi-distro CI (Ubuntu 22.04/24.04, Debian 12)
├── docs/
│   ├── adr/
│   │   ├── 0001-lightweight-remote-server-profile.md
│   │   └── 0002-modular-architecture.md
│   └── agents/                    # SDD workflow conventions
├── GLOSSARY.md                    # Domain language
├── CLAUDE.md                      # AI Assistant rules
├── LICENSE                        # MIT License
└── README.md
```

---

## 🧪 Testing & Verification

Run the automated test suite locally:

```bash
./tests/run_all_tests.sh
```

Build the standalone single-file installer:

```bash
./bundle.sh
```

---

## 📄 License

MIT © [littfed](https://github.com/littfed)
