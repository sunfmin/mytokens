# A vault item's digest is a field, not a tag

Supersedes ADR-0022's ownership by the `mytokens-digest-<hash>` tag and its rejected option "Store a digest as a
field". ADR-0024 (the layout) and ADR-0025 (Adopting an optokens item) stand, with the digest in a field.

## Context

Felix, 2026-11-27, with a screenshot of 1Password's sidebar listing dozens of `mytokens-digest-05e91bae773a6…`
tags: 「侧面加了太多的这个。用别的。」 Every item the sync owned carried a tag of its own; a tag is a sidebar entry,
so a per-item hash must not be one.

ADR-0022 kept the digest in a tag because a tag shows in one `op item list`, so an unchanged sync reads no values.
That reason no longer holds: since the two-way sync (mytokens#13) the vault memory (per Mac) remembers each owned
item's listed `version` and digest, and an item whose listed version is the remembered one is not read at all; any
other is read before it is compared. The digest is needed only on items that are read anyway.

## Decision

- **The digest is a field.** An item the sync writes carries the digest of what it holds as the field `digest`
  (STRING) of a section `mytokens`. Its tags are `optokens` and `mytokens`, beside any other tag it already had;
  no `mytokens-digest-*` tag is written. The section is not the Secret's: the digest does not count it, and
  `decodeVaultItem` (and a hand-made item's decoding) reads past it. optokens reads past a section it does not own
  and keeps it on `put`.
- **Ownership.** An item is the sync's own when this Mac's vault memory knows its id, or, once read, it has that
  field. A `mytokens`-tagged item the memory does not know is read once to tell (reads are outside the write
  budget); without the field it is a hand copy, taken over as ADR-0022 says. An item with an older mytokens'
  `mytokens-digest-*` tag is the sync's own too, its tag giving the digest it last wrote. An optokens item
  (ADR-0025) with neither is optokens', Adopted by its section.
- **What the item says.** Without memory, the field (or the old tag) is what the sync last wrote, as the digest
  tag was: an item changed in 1Password only is Adopted, changed on the Mac only is written, changed on both is a
  conflict. A rewrite that leaves the item's content as it is (ADR-0025's) adds the tag `mytokens` and sets the
  field, nothing else.
- **Migration.** The format is `mytokens-vault-5`, so every owned item reads as changed and the next sync
  rewrites it once: the old digest tag goes, the section `mytokens` comes. A write past the service account's
  budget is `deferred` to the next run, as any other.

## Considered Options

- **One ownership tag, the digest in the vault memory only.** Rejected: a Mac without the memory could not tell a
  1Password change from a Mac change.
- **The digest in the notes.** Rejected: the layout empties the notes of an item it takes over, and optokens shows
  them.

## Consequences

- 1Password's sidebar lists `optokens` and `mytokens` for the vault, not one tag per item. An archived item keeps
  its old tag.
- A sync without memory reads every `mytokens`-tagged item once, where the tag let it read none; with memory,
  as every Background Sync has, an unchanged vault is still one `item list`.
- Undo: bump the format again and write the tag back.
- Checked against a fake `op` and optokens' layout fixtures; the real run on `devbox` after the release is the
  owner's (ADR-0022).
