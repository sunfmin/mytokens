# mytokens

A Claude Code skill + signed macOS Helper app that stores machine-usable secrets in the
iCloud Keychain and lets Claude auto-retrieve and mint them when calling APIs. See
`CONTEXT.md` for the domain glossary and `docs/adr/` for architectural decisions.

## Agent skills

### Issue tracker

Issues live in factorium's local tracker (`factorium issue …`, checkout `mytokens`). See
`docs/agents/issue-tracker.md`.

### Gate

`factorium.toml` runs `./gate.sh` (`make test`); what it needs on a host is in
`docs/agents/afkconvoy.md` (gate-needs), whose cut section is not yet moved to factorium.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root. See
`docs/agents/domain.md`.
