# mytokens

A Claude Code skill + signed macOS Helper app that stores machine-usable secrets in the
iCloud Keychain and lets Claude auto-retrieve and mint them when calling APIs. See
`CONTEXT.md` for the domain glossary and `docs/adr/` for architectural decisions.

## Agent skills

### Issue tracker

Issues live in the tracker the host names (sunfmin/control, control ADR 0002), labelled
`repo:sunfmin/mytokens`; open them with the line `afkconvoy flows` gives. External PRs are
**not** a triage surface. See `docs/agents/issue-tracker.md`.

### afkconvoy

The fleet goes by `docs/agents/afkconvoy.md`; the gate is `./gate.sh`.

### Triage labels

The five canonical triage roles use their default label strings (`needs-triage`,
`needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See
`docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root. See
`docs/agents/domain.md`.
