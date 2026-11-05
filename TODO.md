# Project Roadmap & Backlog

## Current Work & Ready for Implementation

- [x] **Feature: Network Bandwidth Throughput & Multi-Stream Speedtest (Tickets 24–26)**
  - **Status**: Completed & Verified with comprehensive test suite
  - **Spec**: [`.scratch/network-speedtest/spec.md`](.scratch/network-speedtest/spec.md)
  - **Issues**:
    - [x] [24: Network Bandwidth Engine: Upload Speed, Mbit/s & Multi-Region Diagnostics](.scratch/network-speedtest/issues/24-network-bandwidth-upload-and-mbit.md)
    - [x] [25: Multi-Stream Speedtest Engine (`modules/diagnostics/speedtest.sh`)](.scratch/network-speedtest/issues/25-multi-stream-speedtest-engine.md)
    - [x] [26: CLI Integration, Bundling, Automated Tests & Documentation](.scratch/network-speedtest/issues/26-speedtest-cli-bundling-and-tests.md)

- [x] **Feature: Server Diagnostics, Pre-Flight, Docker Log Limits, Time Sync & Rollback (Tickets 18–23)**
  - **Status**: Completed & Verified with comprehensive test suite
  - **Spec**: [`.scratch/diagnostics-and-management/spec.md`](.scratch/diagnostics-and-management/spec.md)
  - **Issues**:
    - [x] [18: Pre-Flight Sanity & Auto-Adaptation Engine (`core/preflight.sh`)](.scratch/diagnostics-and-management/issues/18-preflight-sanity-and-autoadaptation.md)
    - [x] [19: Hardware & Network Benchmark Module (`modules/diagnostics/bench.sh`)](.scratch/diagnostics-and-management/issues/19-hardware-and-network-benchmark.md)
    - [x] [20: Docker Log Rotation & Storage Protection (`core/docker.sh`)](.scratch/diagnostics-and-management/issues/20-docker-log-rotation-limits.md)
    - [x] [21: Accurate Time Synchronization Module (`core/time.sh`)](.scratch/diagnostics-and-management/issues/21-accurate-time-sync.md)
    - [x] [22: Configuration Rollback & Backup Engine (`modules/maintenance/rollback.sh`)](.scratch/diagnostics-and-management/issues/22-configuration-rollback-engine.md)
    - [x] [23: CLI Integration, Bundling, Automated Tests & Documentation](.scratch/diagnostics-and-management/issues/23-cli-integration-bundling-tests.md)

- [x] **Feature: Server Security Hardening & Performance Integration (Tickets 13–17)**
  - **Status**: Completed & Verified with comprehensive test suite
  - **Spec**: [`.scratch/security-hardening/spec.md`](.scratch/security-hardening/spec.md)
  - **Issues**:
    - [x] [13: Core System Tuning & Network Hardening (`core/system.sh`)](.scratch/security-hardening/issues/13-core-system-tuning-and-network-hardening.md)
    - [x] [14: SSH Hardening Module (`modules/security/ssh.sh`)](.scratch/security-hardening/issues/14-ssh-hardening-module.md)
    - [x] [15: Firewall & Docker-User Integration Module (`modules/security/firewall.sh`)](.scratch/security-hardening/issues/15-firewall-docker-integration-module.md)
    - [x] [16: Adaptive Intrusion Prevention Module (`modules/security/ids.sh`)](.scratch/security-hardening/issues/16-adaptive-intrusion-prevention-ids.md)
    - [x] [17: CLI Metaflag Integration, Bundling & Automated Tests](.scratch/security-hardening/issues/17-cli-metaflag-bundling-and-automated-tests.md)

## Backlog & Pending Decisions

- [ ] **Issue 12: Pure-Bash Crash Log Sanitizer & One-Click GitHub Issue Reporting**
  - **Status**: Backlog / Under consideration
  - **Spec**: [`.scratch/error-reporting/spec.md`](.scratch/error-reporting/spec.md)
  - **Issue**: [`.scratch/modular-server-setup/issues/12-error-crash-reporting.md`](.scratch/modular-server-setup/issues/12-error-crash-reporting.md)
  - **Summary**: Intercept runtime failures, redact sensitive host data, save sanitized crash log, and offer an interactive prompt to generate a pre-filled GitHub Issue link under 2 KB.
