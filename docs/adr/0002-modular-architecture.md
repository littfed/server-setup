# 2. Modular Architecture: Core, Adapters, and Extension Modules

Date: 2026-11-04
Status: Accepted

## Context

The initial prototype proved that a lightweight remote server setup can be completed entirely outside of Dokploy's codebase, reducing idle RAM from ~500 MB to ~100 MB. To expand the project into a comprehensive open-source toolkit and support multiple PaaS platforms (Dokploy, Coolify, Portainer, Standalone) alongside optional proxying, tunneling, and automated maintenance, a modular architecture is required.

Coupling control plane API logic with low-level Linux/Docker tuning makes the codebase fragile, hard to test, and difficult to extend.

## Decision

We organize the project into three decoupled layers:

1. **Core Layer (`core/`)**:
   - `memory.sh`: System-level memory tuning (ZRAM LZ4 swap priority 100, 1 GB SSD fallback swapfile, sysctl kernel limits, systemd-oomd suppression).
   - `docker.sh`: Docker Engine installation, OCI runtime `crun`, `/etc/docker/daemon.json` optimization (no userland proxy, sequential downloads, buildkit disabled, log rotation), and `GOMEMLIMIT` drop-in.
   - Always runs on the target node. Zero external dependencies.

2. **Adapter Layer (`adapters/`)**:
   - Encapsulates control plane specific interactions via standard interfaces:
     - `adapters/dokploy.sh`: Dokploy API integration (fetch SSH key, register server, handshake).
     - `adapters/coolify.sh`: Coolify API integration.
     - `adapters/portainer.sh`: Portainer Edge Agent integration.
     - `adapters/standalone.sh`: Headless node setup without control plane.

3. **Extension Modules Layer (`modules/`)**:
   - `modules/ingress/cloudflare.sh`: Installs `cloudflared`, authenticates via token, runs zero-port tunnel.
   - `modules/ingress/caddy.sh`: Installs lightweight Caddy micro-proxy with automated ACME TLS.
   - `modules/maintenance/auto-prune.sh`: Configures low-priority systemd timer (`nice -n 19 ionice -c 3`) for Docker image and cache cleanup based on age and disk threshold.
   - `modules/telemetry/health-cron.sh`: Pure-shell cron reporter gathering metrics directly from `/proc` and alerting via webhook.

4. **Unified Dispatcher (`setup.sh`)**:
   - Single entrypoint CLI accepting arguments and orchestrating execution.
   - Usable locally or piped directly via `curl -sSL ... | sudo bash -s --`.

## Consequences

### Positive
- High extensibility: Adding a new panel adapter (e.g. CapRover) or a new tunnel (e.g. WireGuard/Tailscale) requires adding one self-contained script without modifying core logic.
- Testability: Core, adapters, and modules can be independently unit and integration tested in CI.
- True zero-overhead: Modules are only installed and run if explicitly requested.

### Negative / Trade-offs
- The curl-pipe-bash distribution needs a lightweight packager/bundler or an online loader that fetches required modules during execution.
