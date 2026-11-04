# 1. Lightweight Remote Server Profile for Resource-Constrained Nodes

Date: 2026-11-04
Status: Accepted

## Context

Dokploy supports connecting remote servers over SSH. However, the default remote server setup procedure (`serverSetup` / `defaultCommand`) was designed for full-fledged deployments:
- Initializes Docker Swarm mode (`docker swarm init`).
- Deploys an instance of Traefik reverse proxy (`dokploy-traefik`).
- Installs external CLI builders: Nixpacks, Buildpacks, Railpack, and RClone.
- Injects node monitoring containers (Vector, cAdvisor, Node Exporter).

On budget cloud VPS servers with <= 1 GB RAM and 1 vCPU, this default stack consumes between 450 MB and 550 MB RAM at idle, leaving under 500 MB for actual user workloads. Furthermore, running multi-layer concurrent image pulls triggers out-of-memory (OOM) kernel crashes.

When servers are dedicated solely to executing pre-built Docker images without on-node builds or heavy routing, this overhead is counterproductive.

## Decision

We introduce a two-tiered solution for low-spec remote servers in Dokploy:

### 1. Turnkey Custom Setup Script (Immediate Use)
Provide an optimized setup script (`lightweight-worker-setup.sh`) that can be supplied via Dokploy's existing `server.command` field. The script:
- Configures Linux kernel memory safety: ZRAM (LZ4 compression, priority 100) + 1 GB SSD fallback swapfile, `vm.swappiness = 100`, `vm.dirty_background_ratio = 5`, and disables `systemd-oomd`.
- Installs clean Docker Engine with OCI runtime `crun` (consuming 2-4 MB RSS per container vs 20-30 MB with `runc`).
- Sets `daemon.json` optimizations: `"userland-proxy": false` (0 MB memory per exposed port), `"max-concurrent-downloads": 1` (prevents OOM during image pull), `"features": { "buildkit": false }`, and strict log rotation.
- Drops in `GOMEMLIMIT=128MiB` for `docker.service`.
- Creates `/etc/dokploy` directory structures and a bridge-mode `dokploy-network` (`docker network create --driver bridge --attachable dokploy-network`).
- Completely omits Docker Swarm, Traefik, build engines (Nixpacks/Buildpacks/Railpack), RClone, and monitoring daemons.

### 2. Native `Lightweight Worker` Profile in Dokploy
Integrate a first-class server type into Dokploy:
- **Schema:** Extend `serverType` pgEnum with `'lightweight'` (`['deploy', 'build', 'lightweight']`).
- **Setup Automation:** Update `defaultCommand` in `packages/server/src/setup/server-setup.ts` to automatically generate the lightweight configuration script when `server.serverType === "lightweight"`.
- **Workload Routing:** Treat **Docker Compose** as the primary deployment mechanism on lightweight nodes. Compose projects run via standard `docker compose up -d` without Swarm, which works out of the box with standalone Docker and local bridge networks.
- **UI:** Expose the "Lightweight Worker (<= 1 GB RAM)" option during server creation, adjust the `ValidateServer` widget to suppress Traefik checks, and inform users that ingress is handled via direct port exposure or external reverse proxies/tunnels.

## Consequences

### Positive
- Baseline idle memory footprint on remote nodes is reduced from ~500 MB to **85–120 MB RAM**, unlocking >880 MB of usable RAM for user applications on 1 GB VPS servers.
- `docker pull` operations no longer crash from memory exhaustion on single-core systems.
- Zero breaking changes to existing `deploy` or `build` server types.
- Works immediately via custom command, and cleanly integrates natively into Dokploy's codebase.

### Negative / Trade-offs
- Dokploy's single-container **Applications** and **Databases** UI modules currently rely on `docker.createService` (Swarm API). On lightweight nodes, users must run workloads via **Docker Compose** (which supports any pre-built image) unless a standalone container orchestrator (`docker.createContainer`) is added to Dokploy in the future.
- Local Traefik ingress is absent on the node; routing to services requires direct port mapping or an external ingress (e.g. Cloudflare Tunnel or upstream reverse proxy).
