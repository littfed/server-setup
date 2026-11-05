# Project Roadmap & Backlog

## Current Work & Ready for Implementation

- [ ] **Feature: Server Diagnostics, Pre-Flight, Docker Log Limits, Time Sync & Rollback (Tickets 18–23)**
  - **Status**: Ready for implementation (`ready-for-agent`)
  - **Spec**: [`.scratch/diagnostics-and-management/spec.md`](.scratch/diagnostics-and-management/spec.md)
  - **Issues**:
    - [ ] [18: Pre-Flight Sanity & Auto-Adaptation Engine (`core/preflight.sh`)](.scratch/diagnostics-and-management/issues/18-preflight-sanity-and-autoadaptation.md)
    - [ ] [19: Hardware & Network Benchmark Module (`modules/diagnostics/bench.sh`)](.scratch/diagnostics-and-management/issues/19-hardware-and-network-benchmark.md)
    - [ ] [20: Docker Log Rotation & Storage Protection (`core/docker.sh`)](.scratch/diagnostics-and-management/issues/20-docker-log-rotation-limits.md)
    - [ ] [21: Accurate Time Synchronization Module (`core/time.sh`)](.scratch/diagnostics-and-management/issues/21-accurate-time-sync.md)
    - [ ] [22: Configuration Rollback & Backup Engine (`modules/maintenance/rollback.sh`)](.scratch/diagnostics-and-management/issues/22-configuration-rollback-engine.md)
    - [ ] [23: CLI Integration, Bundling, Automated Tests & Documentation](.scratch/diagnostics-and-management/issues/23-cli-integration-bundling-tests.md)

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
