# Store secrets in the iCloud Keychain via a code-signed helper, under our own access group

We store machine-usable secrets in the macOS **data-protection (iCloud) keychain**
through a **code-signed Swift helper** (Apple Developer identity + `keychain-access-groups`
entitlement), writing synchronizable items under **our own access group**
(`<TeamID>.<bundle-id>`). We deliberately do **not** use the legacy login keychain, and we
accept that entries will **not** appear in the Passwords.app UI.

## Considered Options

- **Login keychain via `/usr/bin/security`** — simplest, zero-cost, no signing. Rejected
  because it is local-only (no sync) and the `security` CLI cannot reach the iCloud Keychain
  at all (it only sees `login.keychain-db` + `System.keychain`).
- **1Password CLI (`op`)** — already installed, real synced vault with GUI. Rejected because
  the user wants Apple-native storage; kept on the table as a future alternative backend.
- **Make entries visible in Passwords.app** — requires `SecAddSharedWebCredential` + the
  Associated Domains entitlement + an `apple-app-site-association` file hosted on each
  service's domain. Impossible for third-party services (cloudflare.com, github.com, …) we
  don't control. Ruled out entirely.

## Consequences

- An ad-hoc/unsigned binary gets `errSecMissingEntitlement` (-34018) — **verified by probe**.
  The signed helper is therefore the *sole* read/write path; `security` and plain scripts
  cannot substitute.
- Secrets **sync across the user's Macs** where the helper is installed, but are **not**
  visible in Passwords.app and **not** usable on iPhone (no iOS app shares our access group).
- Requires a paid Apple Developer signing identity. Developer ID certs are long-lived
  (~years), so there is no weekly re-signing burden (unlike free "personal team" signing).
