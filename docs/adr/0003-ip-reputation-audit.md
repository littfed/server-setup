# 3. IP Reputation & Threat Intelligence Audit Module

Date: 2026-11-04
Status: Accepted

## Context

When deploying applications, mail services, proxies, tunnels, or worker nodes on public cloud VPS servers (Hetzner, DigitalOcean, OVH, Vultr, AWS, etc.), operators frequently inherit "dirty" IP addresses previously recycled from abusers, spam campaigns, botnets, or malicious scanners.

Existing diagnostic approaches have notable limitations:
- Manual lookups across web interfaces (AbuseIPDB, MXToolbox, Spamhaus) are slow and not scriptable.
- Commercial threat intelligence services require paid subscriptions or API keys, creating adoption friction in open-source CLI setups.
- Naive sequential DNSBL queries over 20+ blacklists take 30–60 seconds to complete, stalling automated deployments.
- Public DNS resolvers (e.g. Cloudflare 1.1.1.1, Google 8.8.8.8) are blocked by major anti-spam lists (such as Spamhaus return code `127.255.255.254 - Query Refused`).
- Servers may have multiple public network interfaces (e.g. primary IPv4, secondary floating IPv4, and IPv6 prefixes), all of which require verification.

## Decision

We introduce an independent, zero-dependency audit module [`modules/audit/ip-reputation.sh`](../../modules/audit/ip-reputation.sh) and integrate it optionally into [`setup.sh`](../../setup.sh) via `--audit-ip`:

1. **Multi-IP Discovery & Iteration**:
   - Detects all public IPv4 and IPv6 addresses assigned to local interfaces and external egress (`curl -s https://api64.ipify.org`, `ip -o addr`).
   - Supports auditing an explicitly supplied IP address or auditing all detected host IPs sequentially.

2. **Zero-Key First Architecture**:
   - Queries open geolocation and AS endpoints (`ip-api.com`, `ipwho.is`) for ISP name, ASN, organization, country, city, and traffic categorization (hosting, datacenter, residential, proxy/TOR).
   - Queries reverse DNS (rDNS/PTR record) for mail deliverability and domain alignment.
   - Accepts optional API keys (`--abuseipdb-key`, `--virustotal-key`) to enrich results when available.

3. **High-Speed Parallel DNSBL / RBL Engine**:
   - Checks 20+ reputation blacklists (Spamhaus ZEN, Barracuda, SpamCop, DroneBL, UCEPROTECT, SORBS, Abuse.ro, etc.) concurrently via background subshells (`&` / `wait`).
   - Query time reduced from ~30s down to **< 3 seconds**.
   - Filters out reserved open-resolver refusal codes (`127.255.255.x`).
   - Allows passing custom DNS resolvers via `--dns <resolver_ip>` while falling back to local resolvers in `/etc/resolv.conf`.

4. **Risk Scoring & Dual Output**:
   - Computes an aggregate **Risk Score** (0–100) and badges: `CLEAN` (0–10), `SUSPICIOUS` (11–40), `HIGH RISK` (41–100).
   - Terminal mode renders visual colored cards and tabular status.
   - Machine mode (`--json`) emits structured JSON.
   - Automatically saves last audit snapshot to `/var/log/server-setup/ip-audit.json`.

5. **Integration with Provisioning Dispatcher (`setup.sh`)**:
   - Added `--audit-ip` flag to `setup.sh` to run audit during pre-flight.
   - Non-blocking by default (prints clear warnings for bad IPs).
   - Strict mode `--strict-audit` halts setup if `Risk Score > 40` or IP is blacklisted in critical spam lists.

## Consequences

### Positive
- Instantly detects tainted or blocklisted IP addresses before investing time in deploying mail/proxy/web workloads.
- Zero external dependencies beyond standard bash, `curl`, and `dig`/`host`.
- Parallel DNS resolution ensures negligible latency (<3s).
- Full audit results are archived on the host in JSON format for telemetry and monitoring agents.

### Negative / Trade-offs
- Rate limits on free public HTTP endpoints (e.g. 45 req/min on ip-api.com) must be respected; high-frequency batch querying requires user-supplied API keys or relying strictly on DNSBL.
- Certain restrictive cloud firewalls blocking outbound port 53 UDP will cause DNSBL checks to fall back to HTTP threat endpoints.
