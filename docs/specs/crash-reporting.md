# Spec: Error Reporting, Crash Dump & Log Sanitizer (Pure Bash)

Status: Draft / Under Consideration

## Summary
A lightweight, zero-dependency, pure-Bash error trap mechanism that:
1. Intercepts runtime errors via `trap 'on_error' ERR`.
2. Automatically redacts all sensitive data (IPv4/IPv6, tokens, secrets, private keys, custom domains, username).
3. Saves a full sanitized crash log to `/tmp/server-setup-crash.log`.
4. Asks the user interactively `[Y/n]` (with a `[v]` preview option) before generating a compact, pre-filled GitHub Issue URL (< 2 KB) using terminal OSC 8 hyperlinks.
5. In non-interactive environments (CI, cron, `curl | bash`), outputs the sanitized link and log without blocking.

See [TODO.md](../../TODO.md) and [`.scratch/error-reporting/spec.md`](../../.scratch/error-reporting/spec.md) for complete details.
