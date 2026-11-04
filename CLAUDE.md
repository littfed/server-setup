# Server Setup & Lightweight Agent

Open-source toolkit and agent for configuring lightweight Linux worker servers (<= 1 GB RAM) and seamlessly connecting them to container orchestrators and control planes like Dokploy.

## Code Style
- Shell scripts follow Google Shell Style Guide: `set -e`, strict error handling, explicit quotes, and POSIX compliance where possible.
- Documentation in standard Markdown with Mermaid sequence and architecture diagrams.
- Clean separation between core optimization logic and control plane integrations.

## Agent skills

### Issue tracker

Issues and specs live as markdown files under `.scratch/<feature>/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Canonical triage roles mapped to standard label strings. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context (`GLOSSARY.md` and `docs/adr/` at repo root). See `docs/agents/domain.md`.
