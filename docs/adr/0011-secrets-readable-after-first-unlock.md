# A Secret is readable while the screen is locked, once the Mac has been unlocked since boot

Every iCloud Keychain item mytokens writes on a personal Mac carries
`kSecAttrAccessibleAfterFirstUnlock`. The Helper can read a **Secret** whenever the Mac has
been unlocked once since it booted, whether the screen is locked or not. Before this, items
took the system default, `kSecAttrAccessibleWhenUnlocked`, so they could be read only while the
screen was unlocked. Items stored with that old default are moved to the new accessibility
automatically, the first time mytokens runs on an unlocked Mac.

## Context

The fleet and other unattended jobs run on the user's personal Macs while nobody sits at
them, so the screen is locked. `mytokens get` / `env` failed there with `keychain is locked
(interaction not allowed)`. `KeychainSecretStore` never set `kSecAttrAccessible`, so its items
had the default class. With the screen locked, `SecItemCopyMatching` returned
`errSecInteractionNotAllowed`. Felix's decision (sunfmin/control#550, 2026-11-03) was to drop
that requirement.

## Decision

- **Accessibility.** On the iCloud Keychain, every write (`SecItemAdd` and the update half of
  `put`'s upsert) sets `kSecAttrAccessibleAfterFirstUnlock`. It is the synchronizable class,
  not `…ThisDeviceOnly`, so iCloud sync between the user's Macs keeps working. The value has
  one home: `KeychainSecretStore.accessibility`, beside the per-location query scoping.
  Accessibility is **not** a query key, so an item still at the old default stays findable.
- **Migration.** `KeychainSecretStore.opened(_:)` is how the live dependencies build the
  store. It first runs one `SecItemUpdate`: every item in our access group that is still
  `kSecAttrAccessibleWhenUnlocked` moves to `AfterFirstUnlock`. Values and other attributes
  are untouched, and there is no popup. Nothing has to remember to run it, because every
  command opens the store this way. It is idempotent: once the items have moved, the query
  matches nothing (`errSecItemNotFound`). It is best effort: while the screen is locked, the
  old items cannot be touched (`errSecInteractionNotAllowed`). The command carries on, and the
  next run on an unlocked Mac moves them.
- **Server unchanged.** The login keychain (ADR-0010) has no data-protection classes. A
  Server's items are written exactly as before, and the migration does nothing there.
- **Before first unlock.** After a reboot, before anyone has logged in, a Secret still
  cannot be read. The `.locked` error says so, and says what to do: log in once, at the Mac or
  over Screen Sharing, then retry.

## Considered Options

- **Keep `WhenUnlocked`, so jobs need an unlocked screen.** Rejected by Felix: the Macs run
  jobs while nobody is at them, and an always-unlocked screen is worse than this.
- **`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.** Rejected: the item would stop
  syncing through the iCloud Keychain (ADR-0001).
- **A one-off migration command.** Rejected: someone would have to remember to run it on each
  Mac. Running the migration when the store opens takes one cheap keychain call, and it
  converges on its own.

## Consequences

- Trade-off: while the screen is locked, any process that can run the signed Helper as the
  user can read a Secret. That is any process in the user's sessions, including SSH sessions
  and background jobs. Before, this was possible only while the screen was unlocked. The
  access-group scoping and the code-signing requirement (ADR-0001) are unchanged. Before the
  first unlock after boot, nothing can read a Secret.
- ADR-0001 stands, apart from the accessibility class it left at the default.
- `selftest` rewrites its single-value probe, so the update path, which sets the
  accessibility, runs against the real keychain at every install.

## Verified

On macs-Mac-Mini, 2026-11-03 19:42 JST, with v0.1.6 (the first release with this decision)
installed and the console screen locked (`pmset displaysleepnow`, then
`CGSSessionScreenIsLocked=Yes` in `ioreg -n Root -d1`), a background session with no
console read and wrote Secrets: `mytokens list` exit 0, `mytokens get <service>` exit 0, and
`mytokens selftest` → `SELFTEST PASS`. With 0.1.5 the same reads had failed with
`keychain is locked (interaction not allowed)`, before anyone had logged in since boot
(sunfmin/control#551). After a login, 0.1.5 also read while the screen was locked, so this
check shows that nothing regressed. It does not show a before/after difference on this Mac.
