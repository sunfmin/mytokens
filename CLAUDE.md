# mytokens

A Claude Code skill + signed macOS Helper app that stores machine-usable secrets in the
iCloud Keychain and lets Claude auto-retrieve and mint them when calling APIs. See
`CONTEXT.md` for the domain glossary and `docs/adr/` for architectural decisions.

## Agent skills

### Issue tracker

Issues live in this repo's GitHub Issues (via the `gh` CLI); external PRs are **not** a
triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles use their default label strings (`needs-triage`,
`needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See
`docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root. See
`docs/agents/domain.md`.
