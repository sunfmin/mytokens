# A Server stores Secrets in local data-protection keychain items, not its login keychain

A Server's Secrets live in non-synchronizable items in the macOS data-protection keychain,
under mytokens' access group and with `kSecAttrAccessibleAfterFirstUnlock`. This amends
ADR-0010's login-keychain store and extends ADR-0011's accessibility rule to a Server. The
signed Helper and the `SecretStore` seam stay the same.

## Context

ADR-0010 assumed a Server's login keychain was readable over SSH while its console screen was
locked. On mini-jp, reached through Tailscale SSH as felix with felix logged in at the locked
console, the session instead has `System.keychain` as its default and cannot read felix's login
keychain. Selecting `login.keychain-db` explicitly would fix only the write-permission failure,
not the locked store.

A Server still does not sign into iCloud. No password that unlocks a store may be kept on it,
and Secret values may cross between Macs only in SSH pipes.

## Decision

- Use generic-password items in the data-protection keychain with
  `kSecAttrSynchronizable = false`, mytokens' existing access group, and
  `kSecAttrAccessibleAfterFirstUnlock`. The only query difference between a personal Mac's
  store and a Server's is whether items synchronize.
- After the Mac's first unlock since boot, every command works over ordinary SSH and Tailscale
  SSH, and in a non-SSH session, whether or not the screen is locked. Before that first unlock,
  the existing `.locked` error applies: log in once at the Mac or over Screen Sharing.
- Keep the whole Secret record, access-group scoping and accessibility migration in
  `KeychainSecretStore`. Sync and its SSH-pipe-only transport are unchanged.
- Do not move or delete legacy login-keychain items automatically: the session that needs this
  change cannot read them. Before upgrading, Sync a Server whose only copy of a Secret was
  entered there so it is Adopted. After upgrading, Sync from a personal Mac restores every
  `server`-level Secret to the new store.

## Considered Options

- **Open `login.keychain-db` explicitly.** Rejected: it fixes the default-keychain write error
  but not the locked-login-keychain read error over Tailscale SSH.
- **Unlock the login keychain with a password kept on the Server.** Rejected by the constraint
  that no store-unlocking password is kept there.
- **Sign the Server into iCloud.** Rejected by ADR-0010: it would give an unattended machine
  every Secret rather than only the `server`-level ones.

## Consequences

- A Server has the same after-first-unlock exposure as a personal Mac: any process running as
  its user can ask the signed Helper to read a Secret while the screen is locked. Its items do
  not synchronize to other Macs.
- Commands no longer see Secrets left in the legacy login keychain. Those items remain where
  they were; the pre-upgrade Sync above is required for anything not already homed on a
  personal Mac.
- `CONTEXT.md`, the README's Server requirements, ADR-0010 and ADR-0011 name the new store.

## Verified

On mini-jp, 2026-11-03, with felix's console session locked and all remote commands carried by
Tailscale SSH:

- A Developer ID-signed build passed `mytokens selftest`, exercising writes, reads, updates and
  deletes against the local data-protection items.
- `mytokens sync felix@mini-jp` from felixmbp14 added all 40 `server`-level Secrets. A remote
  `mytokens list` listed 40, and `mytokens get asc-api-key --field 'Key ID'` produced the same
  SHA-256 hash on both Macs without printing the value.
- The same `get` produced that hash in a non-SSH Orca terminal on mini-jp, and exited 0.
- A second `sync` printed `no changes`.
