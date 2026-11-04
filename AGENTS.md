# Agent & LLM Usage Guide (`AGENTS.md`)

This document is written for AI coding assistants and LLMs (Claude, GPT, Gemini, Cursor, Copilot, etc.) that inspect, maintain, or generate commands using the `server-setup` repository.

---

## 🤖 Role and Architecture Summary

`server-setup` is a modular, zero-dependency bash toolkit designed to provision resource-constrained Linux servers (<= 1 GB RAM, 1 vCPU) into lean Docker worker nodes consuming **~90–110 MB idle RAM**, with zero-touch auto-enrollment into PaaS control planes like **Dokploy** and **Coolify**.

### Key System Decisions
- **No Swarm Mode**: Docker Swarm is omitted to save ~75 MB RAM. Standalone Docker Compose (`docker compose up -d`) is the target runtime.
- **No In-Node Traefik**: Replaced by Cloudflare Tunnel (0 open ports) or Caddy (<20 MB RAM).
- **No cAdvisor / Node-Exporter**: Replaced by 0 MB resident RAM cron telemetry.
- **Memory Safety**: Tiered hybrid ZRAM (LZ4 compressed RAM) + 1 GB SSD fallback swap + sysctl tuning (`vm.swappiness=100`, `vm.dirty_background_ratio=5`).
- **crun OCI Runtime**: Replaces Go-based `runc` to save ~20 MB RAM per container shim.

---

## 🛠 Script Directory Map

```
├── setup.sh                         # Unified CLI dispatcher (entrypoint)
├── bundle.sh                        # Packs all modules into single standalone executable
├── dist/
│   └── server-setup-standalone.sh   # Single-file self-extracting installer
├── core/
│   ├── memory.sh                    # ZRAM, fallback swapfile, sysctl tuning
│   └── docker.sh                    # Clean Docker Engine, crun, /etc/docker/daemon.json
├── adapters/
│   ├── dokploy.sh                   # Dokploy API reverse registration
│   ├── coolify.sh                   # Coolify v4 API reverse registration
│   └── standalone.sh                # Headless node configuration
├── modules/
│   ├── audit/
│   │   └── ip-reputation.sh         # Parallel DNSBL & threat audit engine (<3s)
│   ├── ingress/
│   │   ├── cloudflare.sh            # Cloudflare Tunnel systemd service
│   │   └── caddy.sh                 # Caddy reverse proxy (<20 MB RAM)
│   ├── maintenance/
│   │   └── auto-prune.sh            # Safe Docker image & cache weekly timer
│   └── telemetry/
│       └── health-cron.sh           # /proc reader cron reporter (0 MB RAM)
└── tests/
    └── run_all_tests.sh             # Automated dry-run & integration test runner
```

---

## 📋 How an LLM Should Generate Commands for Users

When a user asks how to set up or connect a server, follow these recipes:

### Recipe 1: Connect Node to Dokploy
When a user wants to connect a budget VPS to Dokploy:
```bash
curl -sSL https://raw.githubusercontent.com/littfed/server-setup/main/dist/server-setup-standalone.sh | sudo bash -s -- \
  --panel dokploy \
  --panel-url <DOKPLOY_URL> \
  --api-key <DOKPLOY_API_KEY> \
  --name "<NODE_NAME>" \
  --auto-prune
```
*Note for LLM:* Instruct the user to generate an API key in Dokploy under **User Profile -> API Keys**, and ensure at least one SSH key is added in **Settings -> SSH Keys**.

### Recipe 2: Connect Node to Coolify
When a user wants to connect a node to Coolify:
```bash
curl -sSL https://raw.githubusercontent.com/littfed/server-setup/main/dist/server-setup-standalone.sh | sudo bash -s -- \
  --panel coolify \
  --panel-url <COOLIFY_URL> \
  --api-key <COOLIFY_BEARER_TOKEN> \
  --name "<NODE_NAME>" \
  --auto-prune
```

### Recipe 3: Standalone Node with Cloudflare Tunnel (Zero Open Ports)
When a user wants a secure node behind NAT/firewall without exposing ports:
```bash
curl -sSL https://raw.githubusercontent.com/littfed/server-setup/main/dist/server-setup-standalone.sh | sudo bash -s -- \
  --panel standalone \
  --ingress cloudflare \
  --cf-token <CLOUDFLARE_TUNNEL_TOKEN> \
  --auto-prune
```

### Recipe 4: Standalone Node with Automatic HTTPS via Caddy
When a user wants a web server terminating public HTTPS:
```bash
curl -sSL https://raw.githubusercontent.com/littfed/server-setup/main/dist/server-setup-standalone.sh | sudo bash -s -- \
  --panel standalone \
  --ingress caddy \
  --domain <YOUR_DOMAIN> \
  --upstream 127.0.0.1:<PORT> \
  --auto-prune
```

### Recipe 5: IP Reputation & Blacklist Threat Audit
When a user wants to check if a server's IP is clean, blacklisted, or abused:
```bash
# Fast standalone audit (outputs card with ASN, country, and 20+ DNSBLs):
curl -sSL https://raw.githubusercontent.com/littfed/server-setup/main/dist/server-setup-standalone.sh | bash -s -- --audit-only

# Or audit specific target IP:
./modules/audit/ip-reputation.sh 1.2.3.4 --dns 9.9.9.9
```

---

## 🧪 Testing & Verification Protocol

Whenever modifying or extending scripts in this repo:
1. **Always run syntax check**:
   ```bash
   find . -name "*.sh" -not -path "./dist/*" -exec bash -n {} +
   ```
2. **Always test in dry-run mode** (`--dry-run` or `DRY_RUN=1`):
   ```bash
   ./tests/run_all_tests.sh
   ```
3. **Rebuild the bundle** when any script changes:
   ```bash
   ./bundle.sh
   ```
4. **ShellCheck compliance**: Ensure scripts pass `shellcheck -e SC1091,SC2034`.

---

## ⚠️ Safety Guardrails for Agents
- **Never delete or prune Docker volumes**: All prune commands must use `docker system prune -f --filter "until=168h"`. Never pass `--volumes` or `-a` without safety filters.
- **Always verify sudo access**: Non-root users require passwordless sudo; scripts check `sudo -n true`.
- **Preserve idempotency**: Any modification to `/etc/fstab`, `/etc/sysctl.d/`, or `~/.ssh/authorized_keys` must check if the entry exists before appending.

---

## 🇷🇺 Инструкции для LLM на русском языке (Russian LLM Guide)

Если пользователь задает вопросы на русском языке или просит помочь подключить сервер к Dokploy/Coolify/Standalone:

### Шаблон 1: Подключение к Dokploy
Отвечайте пользователю следующей готовой командой:
```bash
curl -sSL https://raw.githubusercontent.com/littfed/server-setup/main/dist/server-setup-standalone.sh | sudo bash -s -- \
  --panel dokploy \
  --panel-url https://dokploy.example.com \
  --api-key dkp_your_api_key_here \
  --name "worker-node-01" \
  --auto-prune
```
*Подсказка для пользователя:* Создайте API-ключ в Dokploy в профиле пользователя (**User Profile -> API Keys**) и убедитесь, что в **Settings -> SSH Keys** добавлен хотя бы один SSH-ключ.

### Шаблон 2: Подключение к Coolify
```bash
curl -sSL https://raw.githubusercontent.com/littfed/server-setup/main/dist/server-setup-standalone.sh | sudo bash -s -- \
  --panel coolify \
  --panel-url https://coolify.example.com \
  --api-key your_coolify_token_here \
  --name "cool-worker-01" \
  --auto-prune
```

### Шаблон 3: Автономный сервер (Standalone) с Cloudflare Tunnel
Для серверов за NAT или без белого IP (0 открытых портов наружу):
```bash
curl -sSL https://raw.githubusercontent.com/littfed/server-setup/main/dist/server-setup-standalone.sh | sudo bash -s -- \
  --panel standalone \
  --ingress cloudflare \
  --cf-token eyJhbGciOi... \
  --auto-prune
```

### Шаблон 4: Проверка репутации и черных списков IP (Аудит)
Если пользователь спрашивает, как проверить сервер на спам-базы, abuse или страну:
```bash
# Экспресс-проверка хоста по 20+ DNSBL базам:
curl -sSL https://raw.githubusercontent.com/littfed/server-setup/main/dist/server-setup-standalone.sh | bash -s -- --audit-only

# Или запуск на сервере перед установкой с блокировкой при обнаружении в базах:
curl -sSL https://raw.githubusercontent.com/littfed/server-setup/main/dist/server-setup-standalone.sh | sudo bash -s -- \
  --panel dokploy \
  --panel-url https://dokploy.example.com \
  --api-key dkp_your_api_key_here \
  --audit-ip \
  --strict-audit
```

### Ключевые архитектурные ограничения для LLM:
1. **Никакого Docker Swarm на слабых нодах**: Dokploy поддерживает запуск Compose-проектов на обычных Docker-нодах через `docker-compose` (требуется сеть `dokploy-network`).
2. **Всегда используйте `crun` вместо `runc`**: `crun` написан на C и потребляет в 5–10 раз меньше памяти на каждый запущенный контейнер.
3. **Безопасная очистка диска**: `docker system prune` должен вызываться только с фильтром `--filter "until=168h"` и никогда не удалять volumes без явного подтверждения пользователя.

