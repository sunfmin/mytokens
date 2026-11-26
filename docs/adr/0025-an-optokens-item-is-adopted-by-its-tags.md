# An item optokens put into a synced vault is Adopted by its tags alone

Refines ADR-0022's "Adopt" for an item in optokens' layout (ADR-0024). The rest of ADR-0022 stands.

## Context

Felix, 2026-11-27: 「双向同步要」. An agent on a machine that is not a Mac stores a Secret with
`optokens put` into a vault the sync holds; it should become a `server`-level Secret on the personal Mac, and its
later `optokens put`s should flow back. ADR-0022 Adopted any item by rewriting it into the vault's layout, which
for an optokens item wrote the adoption note into its `description`, and dropped its other tags and sections.

## Decision

- **Adopt, then tag.** An item tagged `optokens` with no `mytokens-digest-*` tag, whose title names no Secret
  here, is decoded by optokens' layout (its `service` and `account` fields, kind, Meta) and stored whole, origin
  `1password:<vault>`, Description `adopted from 1Password vault <v> on <date>` and then the item's own. The item
  is then made the sync's own by an `op item edit` that only adds the tags `mytokens` and `mytokens-digest-<hash>`:
  the template is the item as `op item get` printed it (title, sections, every field with its id, type and value,
  the notes, every other tag). optokens reads it unchanged, and its own `put` keeps mytokens' tags (optokens 0.1.7,
  checked through an `op` stand-in).
- **The digest tag is the item's.** The tag hashes what the item holds; the Mac's Secret differs by the note. The
  vault memory (per Mac, in the vault's status) keeps, beside the item's digest, the Mac's (`mac`, only when they
  differ): the Mac changed when its Secret's digest differs from `mac`, the item changed when its content differs
  from the item's digest. So a second sync writes nothing.
- **Any write that leaves the item's content as it is only retags.** The same edit is used whenever the sync makes
  an item in optokens' layout and of its title its own with content it already holds: a change made with
  `optokens put` and Adopted (the Secret then takes the item's Description; the note goes), `onepassword keep
  <v> <t> 1password`, an adoption cut short, and an item whose digest tag is stale. Anything else (a hand-made
  item, an old layout, a Mac change) is still the full rewrite of ADR-0024.
- When memory is lost, the tag alone says the item is unchanged, so the Mac's Secret (with the note) is written
  over it once: the Mac is the home.

## Considered Options

- **Rewrite the item as for a hand-made one.** Rejected: optokens' `description` would carry mytokens' note, and
  its other tags and sections would go.
- **Keep the note out of the Mac's Description.** Rejected: the issue asks for it, as for every Adopted Secret.

## Consequences

- An item `optokens put` made is listed by `optokens list` as it was; on the Mac it is a `server`-level Secret
  whose origin is the vault.
- Checked against a fake `op` only. The end-to-end run against `devbox` (an `optokens put` on a server, `mytokens
  server sync` on the personal Mac, `get`, `rm`) is the owner's: workers never sync a production vault (ADR-0022).
