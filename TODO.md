# Project Roadmap & Backlog

## Pending Decisions & Backlog

- [ ] **Issue 12: Pure-Bash Crash Log Sanitizer & One-Click GitHub Issue Reporting**
  - **Status**: Backlog / Under consideration
  - **Spec**: [`.scratch/error-reporting/spec.md`](.scratch/error-reporting/spec.md)
  - **Issue**: [`.scratch/modular-server-setup/issues/12-error-crash-reporting.md`](.scratch/modular-server-setup/issues/12-error-crash-reporting.md)
  - **Summary**: Intercept runtime failures, redact sensitive host data (IPs, tokens, passwords, custom domains, username), save sanitized `/tmp/server-setup-crash.log`, and offer an interactive `[Y/n]/[v]` prompt to generate a pre-filled GitHub Issue link under 2 KB.
