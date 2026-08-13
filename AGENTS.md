# Agent Instructions

## Agent skills

### Issue tracker

Issues and specs live in this repository's GitHub Issues. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the canonical Matt Pocock skills triage labels. See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context repository. Read the root `CONTEXT.md` and relevant ADRs under `docs/adr/` when they exist. See `docs/agents/domain.md`.

## Public tracker privacy

Treat every GitHub issue, comment, label, release note, and linked repository artifact as public.

- Never publish credentials, account or email identifiers, device or host names, internal URLs, private repository links, or user-specific absolute paths.
- Never publish prompts, source code observed from agent logs, tool-result bodies, or raw usage logs.
- Use repository-relative paths, public upstream links, and synthetic or irreversibly redacted fixtures only.
- Keep research artifacts containing local paths or real fixtures local until a separately reviewed, sanitized version is safe to commit.
