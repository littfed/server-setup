# Server Setup 🚀

> **Модульный инструментарий инициализации Linux и Docker-узлов с автоматической регистрацией в панелях управления (Dokploy, Coolify).**  
> Превратите бюджетные VPS-серверы (<= 1 ГБ RAM, 1 vCPU) в легковесные, стабильные Docker worker-ноды, потребляющие всего **~90–110 МБ RAM в простое**.

[English](README.md) | [Русский](README.ru.md) | [Инструкция для LLM / AI-агентов](AGENTS.md)

---

## 💡 Проблема

Современные self-hosted PaaS-панели (**Dokploy**, **Coolify** и др.) удобны, но их конфигурация удаленных серверов по умолчанию избыточно тяжеловесна:
- Автоматически инициализирует **Docker Swarm mode** (raft-консенсус, swarm overlay сети).
- Запускает внутри ноды собственный ingress-контейнер **Traefik** (60–100 МБ RAM).
- Устанавливает тяжелые сборочные инструменты (Nixpacks, Buildpacks, Railpack).
- Развертывает агенты непрерывного сбора метрик (Vector, cAdvisor, Node Exporter).

На бюджетных VPS ($2–$5/месяц с 512 МБ – 1 ГБ RAM) этот стек «по умолчанию» потребляет **450–550 МБ оперативной памяти** просто в режиме ожидания. При скачивании многослойного Docker-образа (`docker pull`) на 1 ядре процессор и память перегружаются, вызывая аварийный сбой **OOM (Out-of-Memory)** и зависание сервера.

---

## 🎯 Решение

**`server-setup`** — это модульный bash-инструментарий без внешних зависимостей, который решает эту проблему:

1. **Снижение потребления RAM на 80%**: Docker работает с рантаймом `crun` и оптимизированным `daemon.json`, удерживая общее потребление ОС + Docker в пределах **~100 МБ RAM**.
2. **Защита от OOM-падений**: Двухуровневая гибридная система памяти: быстрый сжатый **ZRAM (алгоритм LZ4)** в оперативной памяти + резервный swapfile на SSD с агрессивным сбросом анонимных страниц (`vm.swappiness=100`, `vm.dirty_background_ratio=5`).
3. **Авторегистрация в один клик («Agent Join»)**: Вы запускаете одну команду на целевом сервере. Скрипт оптимизирует систему, запрашивает через API публичный SSH-ключ вашей панели, авторизует его в `authorized_keys` и регистрирует сервер в Dokploy или Coolify **без единого ручного клика в веб-интерфейсе**.
4. **Модульная архитектура**:
   - **`core/`**: Оптимизация памяти (ZRAM/Swap) и легковесный Docker (`crun`, лимиты памяти daemon).
   - **`adapters/`**: Dokploy, Coolify и Standalone (автономные ноды).
   - **`modules/`**: Cloudflare Tunnel (без открытых портов), Caddy (<20 МБ RAM), безопасный Docker Auto-Prune и телеметрия без фоновых демонов (0 МБ RAM).
5. **100% совместимость с upstream**: Требует **0 правок в кодовой базе Dokploy или Coolify**. Работает со стандартными официальными релизами.

---

## 📊 Сравнение потребления оперативной памяти

| Компонент | Стандартная нода PaaS | С `server-setup` | Экономия |
| :--- | :--- | :--- | :--- |
| **Базовая ОС Linux** | ~70 МБ | ~50 МБ | Лимит journald, отключение лишних служб |
| **`dockerd`** | ~90 МБ | **~40 МБ** | BuildKit выключен, `GOMEMLIMIT=128MiB` |
| **`containerd`** | ~45 МБ | **~18 МБ** | CRI отключен, сжатый GC |
| **`docker-proxy`** | ~10 МБ на порт | **0 МБ** | `userland-proxy: false` (нативные iptables) |
| **Шимы контейнеров** | ~20 МБ / контейнер (`runc`) | **2–4 МБ** (`crun`) | Быстрый легковесный C-рантайм OCI |
| **Docker Swarm Mode** | ~75 МБ | **0 МБ** | Режим Standalone Compose |
| **Traefik Ingress** | ~80 МБ | **0 МБ** | Внешний Cloudflare Tunnel / микро-Caddy |
| **Vector / cAdvisor** | ~100 МБ | **0 МБ** | Телеметрия по крону напрямую из `/proc` |
| **ИТОГО RAM в простое**| **~450–550 МБ** | **~90–110 МБ** | **🔥 ~400+ МБ свободно для ваших приложений!** |

---

## ⚡ Быстрый старт

### 1. Подключение к Dokploy (Обратная регистрация через API)

Подключитесь к вашему новому VPS по SSH и выполните:

```bash
curl -sSL https://raw.githubusercontent.com/littfed/server-setup/main/dist/server-setup-standalone.sh | sudo bash -s -- \
  --panel dokploy \
  --panel-url https://dokploy.example.com \
  --api-key dkp_your_api_key_here \
  --name "worker-node-01" \
  --auto-prune
```

**Что происходит автоматически:**
1. Настраивается ядро Linux, поднимается ZRAM (LZ4) + swapfile, ставится Docker с рантаймом `crun`.
2. Скрипт обращается к API Dokploy (`/api/sshKey.all`) и скачивает публичный SSH-ключ панели.
3. Ключ безопасно добавляется в `~/.ssh/authorized_keys` с правами 600.
4. Автоматически определяется публичный IP и отправляется запрос в `POST /api/server.create` и `POST /api/server.setup`.
5. Создается локальная сеть `dokploy-network`.
6. **Сервер мгновенно появляется в дашборде Dokploy со статусом Online (зеленый)!**

> **Примечание:** В Dokploy создайте API-ключ в разделе **User Profile -> API Keys**, и убедитесь, что в **Settings -> SSH Keys** добавлен хотя бы один SSH-ключ.

---

### 2. Подключение к Coolify

```bash
curl -sSL https://raw.githubusercontent.com/littfed/server-setup/main/dist/server-setup-standalone.sh | sudo bash -s -- \
  --panel coolify \
  --panel-url https://coolify.example.com \
  --api-key your_coolify_token_here \
  --name "cool-worker-01" \
  --auto-prune
```

**Что происходит автоматически:**
1. Оптимизируется память и Docker Engine под низкий объем RAM.
2. Скрипт запрашивает через Coolify API v4 публичный ключ инстанса (`/api/v4/security/keys`).
3. Добавляет ключ в `authorized_keys`.
4. Регистрирует сервер в пуле серверов Coolify через `POST /api/v4/servers`.

---

### 3. Автономный сервер (Standalone) с Cloudflare Tunnel

Если вам нужен защищенный сервер за NAT или фаерволом без открытия входящих портов:

```bash
curl -sSL https://raw.githubusercontent.com/littfed/server-setup/main/dist/server-setup-standalone.sh | sudo bash -s -- \
  --panel standalone \
  --ingress cloudflare \
  --cf-token eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9... \
  --auto-prune \
  --telemetry webhook \
  --webhook-url https://alert.example.com/webhook
```

---

### 4. Автономный сервер с автоматическим HTTPS через Caddy

Если требуется принимать входящий HTTPS-трафик с потреблением прокси менее 20 МБ RAM:

```bash
curl -sSL https://raw.githubusercontent.com/littfed/server-setup/main/dist/server-setup-standalone.sh | sudo bash -s -- \
  --panel standalone \
  --ingress caddy \
  --domain myapp.example.com \
  --upstream 127.0.0.1:3000 \
  --auto-prune
```

---

### 5. Аудит репутации и чистоты IP (Zero-Key Threat Audit)

Проверка всех публичных IPv4/IPv6 сервера по 20+ глобальным базам черных списков (Spamhaus, Barracuda, SpamCop, DroneBL), определение ASN, провайдера, страны и rDNS (PTR-записи):

```bash
# Автономная быстрая проверка любого сервера (определяет собственный IP):
curl -sSL https://raw.githubusercontent.com/littfed/server-setup/main/dist/server-setup-standalone.sh | bash -s -- --audit-only

# Или проверка произвольного IP с указанием DNS-резолвера:
./modules/audit/ip-reputation.sh 1.2.3.4 --dns 9.9.9.9

# Pre-flight проверка перед регистрацией ноды (предупредит при наличии IP в базах или прервет установку с --strict-audit):
curl -sSL https://raw.githubusercontent.com/littfed/server-setup/main/dist/server-setup-standalone.sh | sudo bash -s -- \
  --panel dokploy \
  --panel-url https://dokploy.example.com \
  --api-key dkp_your_api_key_here \
  --audit-ip \
  --strict-audit
```

---

## 🛠 Справочник параметров командной строки (CLI)

```
Основные параметры:
  --panel <type>         Панель управления: dokploy | coolify | standalone (по умолчанию: standalone)
  --panel-url <url>      URL инстанса панели (например: https://dokploy.example.com)
  --api-key <key>        API-ключ или токен авторизации панели
  --name <name>          Отображаемое имя сервера (по умолчанию: текущий hostname)
  --port <port>          SSH-порт сервера для подключения панели (по умолчанию: 22)
  --user <user>          Пользователь SSH для панели (по умолчанию: текущий пользователь)

Аудит репутации и безопасности IP:
  --audit-ip             Включить аудит чистоты публичных IP сервера перед настройкой
  --strict-audit         Прервать установку, если IP найден в черных списках или имеет высокий Risk Score
  --audit-only           Запустить только аудит IP без изменений в системе и Docker
  --dns <ip>             Кастомный DNS-сервер для запросов DNSBL (например: 9.9.9.9, 1.1.1.1)

Параметры Ingress (прокси и туннели):
  --ingress <type>       Тип ingress: none | cloudflare | caddy (по умолчанию: none)
  --cf-token <token>     Токен Cloudflare Tunnel (обязателен для --ingress cloudflare)
  --domain <domain>      Публичный домен (используется для --ingress caddy)
  --upstream <host:port> Целевой адрес проксирования (по умолчанию: 127.0.0.1:3000)

Обслуживание и очистка:
  --auto-prune           Включить безопасную еженедельную очистку Docker (по умолчанию: включено)
  --no-auto-prune        Отключить автоматическую очистку Docker
  --prune-age <age>      Порог возраста удаляемых неиспользуемых слоев (по умолчанию: 168h / 7 дней)

Телеметрия и алерты (без постоянного расхода RAM):
  --telemetry <type>     Режим телеметрии: none | webhook | telegram (по умолчанию: none)
  --webhook-url <url>    URL вебхука для отправки JSON-метрик и алертов
  --tg-token <token>     Токен Telegram-бота для алертов
  --tg-chat <chat_id>    Chat ID в Telegram для получения сообщений

Общие флаги:
  --dry-run              Режим симуляции (проверка без применения изменений в системе)
  -h, --help             Вызов справки
```

---

## 📂 Структура репозитория

```
server-setup/
├── setup.sh                       # Главный CLI-диспетчер
├── bundle.sh                      # Скрипт сборки автономного монолитного инсталлятора
├── core/
│   ├── memory.sh                  # Настройка ZRAM (LZ4), swapfile, sysctl
│   └── docker.sh                  # Установка Docker Engine, рантайм crun, daemon.json
├── adapters/
│   ├── dokploy.sh                 # Адаптер авторегистрации в Dokploy API
│   ├── coolify.sh                 # Адаптер авторегистрации в Coolify API
│   └── standalone.sh              # Адаптер автономной ноды
├── modules/
│   ├── audit/
│   │   └── ip-reputation.sh       # Аудит репутации IP без ключей (DNSBL, ASN, Geo)
│   ├── ingress/
│   │   ├── cloudflare.sh          # Служба Cloudflare Tunnel (0 открытых портов)
│   │   └── caddy.sh               # Микро-прокси Caddy (<20 МБ RAM, авто-SSL)
│   ├── maintenance/
│   │   └── auto-prune.sh          # Systemd-таймер фоновой очистки Docker
│   └── telemetry/
│       └── health-cron.sh         # Сборщик метрик из /proc по cron (0 МБ постоянной RAM)
├── dist/
│   └── server-setup-standalone.sh # Собранный самораспаковывающийся скрипт
├── tests/
│   ├── run_all_tests.sh           # Запуск полного набора юнит/интеграционных тестов
│   ├── test_core.sh
│   ├── test_dokploy_adapter.sh
│   ├── test_coolify_adapter.sh
│   ├── test_auto_prune.sh
│   ├── test_ingress.sh
│   ├── test_telemetry.sh
│   └── test_cli.sh
├── .github/workflows/
│   └── ci.yml                     # Мульти-дистрибутивный CI (Ubuntu 22.04/24.04, Debian 12)
├── docs/
│   ├── adr/                       # Архитектурные решения (ADR)
│   │   ├── 0001-lightweight-remote-server-profile.md
│   │   └── 0002-modular-architecture.md
│   └── agents/                    # Конвенции SDD-разработки
├── GLOSSARY.md                    # Глоссарий терминов проекта
├── AGENTS.md                      # Полное руководство для AI-ассистентов и LLM
├── CLAUDE.md                      # Инструкции для помощника
├── LICENSE                        # Лицензия MIT
├── README.md                      # Документация на английском
└── README.ru.md                   # Документация на русском
```

---

## 🧪 Запуск тестов и сборка бандла

Локальный запуск набора автоматических тестов:

```bash
./tests/run_all_tests.sh
```

Сборка единого самодостаточного скрипта:

```bash
./bundle.sh
```

---

## 📄 Лицензия

MIT © [littfed](https://github.com/littfed)
