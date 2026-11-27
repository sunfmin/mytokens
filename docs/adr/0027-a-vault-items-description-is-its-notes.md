# A vault item's Description is its notes

Supersedes ADR-0024's placement of the Description (a field `description` of the section `optokens`, the notes
emptied). The rest of ADR-0024, ADR-0025 and ADR-0026 stands.

## Context

mytokens#6. 1Password's item list shows a Secure Note's notes under its title (ADR-0022). Once `devbox` was
rewritten in optokens' layout, with the Description in the section and the notes emptied, the list showed titles
only, where the older layout showed e.g. `openmontage-web — openmontage.douwantech.com 的 nginx Basic Auth 登录…`
(Felix, 2026-11-27, screenshot). optokens#21 (released as optokens 0.1.8) moved the Description of optokens'
layout into the notes; the vault holds one format, so the sync follows.

## Decision

- **The notes are the Description, whole.** The sync writes a Secret's Description as the item's notes (the
  `NOTES` field, id `notesPlain`, first among the fields, as optokens 0.1.8 writes it), and no `description` in
  the section `optokens`. A Secret with no Description has empty notes. The rule "notes kept on an item in this
  layout, emptied on any other" goes: the notes are always the Description.
- **Reading.** `decodeVaultItem` takes the section's `description` when it is there and not empty (an item of the
  layout before this one), else the notes, as optokens reads it. So notes edited in 1Password are a change of the
  Description: Adopted at the next sync, or a conflict when the Mac changed it too (ADR-0022).
- **Migration.** The format is `mytokens-vault-6`, so every owned item reads as changed and the next sync
  rewrites it once, the Description moving into the notes; a write past the budget is `deferred`. Where the sync
  only marks an item its own in place (ADR-0025, or a sync without vault memory whose item already holds the
  Mac's Secret), that edit also moves a section `description` into the notes, as optokens' next `put` would.

## Considered Options

- **The section only (ADR-0024).** Rejected: 1Password's list shows the notes, not a section.
- **Both the section and the notes.** Rejected in ADR-0024 and again: one fact, one home.

## Consequences

- 1Password's item list shows each Secret's Description under its title again; `optokens list` shows the same.
- The fixtures `Tests/Fixtures/optokens-*.json` are optokens 0.1.8's (the bare ones by its rules);
  `optokens-0.1.7-put.json` keeps the previous layout for the migration tests.
- Undo: a new format that writes the section again.
