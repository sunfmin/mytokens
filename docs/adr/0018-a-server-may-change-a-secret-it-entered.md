# A Server may change in place a Secret it entered, and the adopted copy follows

Amends ADR-0012. A Secret **entered on a Server and adopted** by a personal Mac keeps that
Server as its **origin**: the Server may still `put` into it, and the next `sync` carries the
new values to the personal Mac, whose adopted copy follows the Server's. A Secret entered on a
personal Mac and pushed to a Server stays read-only on the Server, as ADR-0012 decided.

## Context

Guild keeps the Hub's Forgejo tokens in mytokens on the Hub, a Server. Once `sync` adopted
`guild-hub`, ADR-0012's refusal (sunfmin/control#800) kept the Hub from ever rotating it in
place, so each rotation went into a new Secret: `guild-hub`, `guild-hub-2`, `guild-hub-3`,
`guild-hub-4` (Guild ADR 0017). Every reader searched from the newest back, and revoked tokens
stayed behind in the older ones. Felix (sunfmin/control#890, 2026-11-14) wants one Secret
replaced in place: its origin is the Server, and a personal Mac only holds the adopted copy.

## Decision

Sync marks, kept with each Secret's metadata (never its values):

- On a **Server**, a pushed Secret that was entered there is also marked **adopted**. Every
  push names, per Secret, whether the receiving Server is its origin, so the mark is set (or
  dropped) by the personal Mac each `sync`.
- On a **personal Mac**, an adopted Secret records its **origin**, the Server it was entered
  on. A Secret adopted before this mark existed is known by its Description's
  `adopted from <host> on <date>` note.
- On either side, `put` into such a Secret marks it **changed** since the last `sync` between
  the two.

Then:

1. On a Server, `put` into a pushed Secret is refused (ADR-0012) unless it is marked adopted.
   An adopted one is changed in place and marked changed; it stays pushed.
2. `get --unpushed` writes the Secrets entered on the Server and not yet adopted, as before,
   and also every adopted one changed there since the last `sync`, saying so.
3. The personal Mac's Adopt step takes such a change into its copy — Fields, kind, meta and
   Description, the adoption note already in it — when its copy is `server`-level, has that
   Server as its origin, and was not changed here. It prints `adopted <name>`, and the push
   marks the Server's copy unchanged again. A copy this Mac no longer holds is adopted afresh.
4. **Both sides changed it** since the last `sync` (or the copy here is now `personal`): a
   conflict, as ADR-0012's — neither side changes, both keep their values, `sync` prints
   `conflict <name>: changed on <host> and on this Mac since the last sync; neither changed`
   and exits non-zero after everything else is done. The push leaves the Server's changed copy
   in place: it neither overwrites nor removes it. A human settles it, e.g. `rm` on this Mac
   takes the Server's copy at the next `sync`; `rm` on the Server keeps this Mac's.
5. A change on the personal Mac reaches the Server at the next `sync` as before; once that
   push succeeds, the copy here is no longer changed.

Other Servers that hold the Secret get it from the personal Mac as any pushed Secret and
refuse `put` into it: only its origin may change it.

## Considered Options

- **A series of Secrets, one per rotation** (what Guild did). Rejected: readers must search,
  and revoked tokens linger.
- **Detect a two-sided change by comparing hashes of the values.** Rejected: a hash of a
  low-entropy value kept in a keychain attribute leaks it. The changed marks need no values.
- **Let the Server overwrite the personal Mac's copy even when both changed.** Rejected: the
  personal Mac's change would be lost silently; a conflict keeps both and says so.

## Consequences

- ADR-0012's "a Server must never be able to overwrite a Secret on the user's own Macs" now
  holds for every Secret whose origin is a personal Mac. A Secret whose origin is a Server
  follows that Server, which iCloud Keychain sync then carries to every personal Mac.
- `put` on a Server into an existing lone-value Secret now replaces its value. It had counted
  the level a Server forces on every `put` as a `--level` request and kept the old value.
- A Server whose mytokens predates this keeps refusing `put` into every pushed Secret; update it.
