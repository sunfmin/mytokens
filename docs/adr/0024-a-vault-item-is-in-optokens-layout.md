# A 1Password vault item is in optokens' layout

Supersedes the item mapping of ADR-0022 (1Password vault) and ADR-0020 (a list Field as sections),
and their `jq` programs. The rest of ADR-0022 (which Secrets, ownership by tag, two-way sync,
conflicts, the write budget) stands.

## Context

mytokens#3. Felix, 2026-11-27: 「让 mytokens 导入到 1password 直接成 optokens 的格式」. optokens
is mytokens' sibling for machines that are not Macs: it keeps Secrets in a 1Password vault through a
service account, one item each (`optokens help secrets`). The vault the sync writes held them in
mytokens' own mapping, read on such a machine by `op` and the `jq` programs in `skills/mytokens/op/`.
Two formats in one vault meant `optokens` could not read what mytokens wrote.

## Decision

- **One layout.** The sync writes each `server`-level Secret as the item `optokens put` writes for the
  same Secret (optokens#16, #17, #18):
  - title `<service>`, or `<service>.<account>` when the account is not `default`;
  - category Secure Note, tag `optokens`, and beside it mytokens' own tag `mytokens` and the section
    `mytokens` with the field `digest`, by which the sync knows its items (ADR-0026; it was a tag
    `mytokens-digest-<hash>`, ADR-0022);
  - every Field a field of the section `fields`, in the Secret's Field order; a lone value is one
    field `value`. No `order` or `ids` metadata;
  - the section `optokens`: `service`, `account`, `kind` (`static` | `profile`), `shape` (`value` |
    `fields`), `description` when there is one, and `meta` (compact JSON) when there is Meta. The
    Description lives there, not in the notes (one home).
- **Field types.** mytokens does not record whether a value came from `--set`. A Field the vault item
  already has keeps its type (STRING or CONCEALED, as optokens or a person set it); a new Field is
  CONCEALED. A type is not content: the digest does not count it.
- **Read back with the same layout.** `decodeVaultItem` is the inverse of the template (round trip
  tested), and refuses what optokens refuses (no tag `optokens`, a stray field in its section, a kind
  other than static or profile, a shape its fields do not fit). It takes the name from the section, never
  from the title. Notes and other sections are not the Secret's. An item optokens wrote (tag
  `optokens`, the section `optokens`) that the sync does not own is Adopted by that section, its kind,
  Meta and types kept, and only tagged (ADR-0025); any other is read as hand-made (ADR-0022), each field a Field by its label.
- **What the layout cannot hold is not written:** a `parent` Secret (fix: `mytokens put <svc> --kind
  static`) and a Secret with a list Field (fix: `mytokens put <svc> --level personal`). The sync says
  `not written <title>: <why>; fix: <command>`, `onepassword list` shows the line, and an item already
  in the vault under that title is left as it is. The rest of the vault syncs.
- **The migration is a rewrite.** The layout's format version (`mytokens-vault-4`; `-5` since ADR-0026) is in the digest,
  so every item an older mapping wrote reads as changed and the next sync rewrites it once, over the
  item as it is: the old top-level Fields and the `mytokens` section go, the notes are emptied (they
  were the Description), and a Login's built-in `username` and `password`, which cannot be removed, are
  kept by id and emptied. An item already in this layout keeps its notes. An old item changed in
  1Password since the last sync cannot be read in the new layout, so the Mac's Secret is written over it.
- **A machine that is not a Mac reads the vault with optokens** (`optokens get|env|list`); one Field
  with `op` alone: `op read "op://<vault>/<title>/fields/<Label>"`. The `jq` programs are removed, and
  `make test` no longer needs `jq`.

## Considered Options

- **Every Field CONCEALED.** Rejected: it would hide a value optokens or a person chose to show.
- **Record which Fields came from `--set`.** Rejected: a new store field for a display choice.
- **The Description in both the section and the notes.** Rejected: one fact, one home; `optokens list`
  shows the section's.
- **Archive the item of a Secret the layout cannot hold.** Rejected: that removes a value from the vault
  over a format; the line names the fix and the item waits.

## Consequences

- `optokens list` shows every `server`-level Secret the sync wrote, and `optokens get` / `env` give
  what `mytokens get` / `env` give.
- A list Field no longer reaches the vault (ADR-0019 stands on the Mac and on Servers).
- The fixtures in `Tests/Fixtures/optokens-*.json` are what optokens 0.1.6 hands `op item create`
  (recorded from a stand-in `op`), the bare ones built by optokens' `item::template` rules; a capture
  through real `op` and the check against `devbox` are mytokens#3's.
