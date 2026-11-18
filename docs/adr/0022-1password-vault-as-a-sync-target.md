# A 1Password vault is one more Sync target, for machines that are not Macs running mytokens

`mytokens onepassword add <vault>` makes a 1Password vault hold exactly this Mac's `server`-level
Secrets, one item each, written with a 1Password **service account**. Background Sync keeps it
current. A Linux box or a CI job reads it with its own read-only service account.

## Context

Felix, 2026-11-18 (control session): 「把里面的数据标记成 server 的，直接导到 1Password 的 service
account」. A Server (ADR-0010) is a Mac running mytokens. Other machines have no mytokens and no
keychain, but can run `op`. The Level `server` already means "may be held by machines other than
my personal Macs", so no new level is introduced: a vault is one more target, with the same rule
as a Server — every `server`-level Secret goes to every target (ADR-0012).

## Decision

- **Glossary: 1Password vault** — a vault named by `onepassword add`, written by Sync. It is
  *not* a Server (nothing runs mytokens there) and it is one-way: nothing is Adopted from it.
- **The vault list** is kept like the Server list (ADR-0015): one synchronizable keychain item
  (service `mytokens.onepassword-vaults`, account `vaults`), vault names only, not a Secret;
  `put` and `rm` refuse its service. `onepassword add <vault>` first makes the vault hold the
  Secrets and lists it only if that worked; `onepassword rm <vault>` makes it hold none of what
  mytokens made, then unlists it; `onepassword list` prints each vault with its last sync or
  failure and the line that fixes it. All refused on a Server.
- **The credential** is a Secret on the personal Mac: service `1password-service-account`,
  account `default`, a lone value, `personal` level. It is never exported — not even if someone
  gives it `server` level. It reaches `op` only as `OP_SERVICE_ACCOUNT_TOKEN` in the `op` child's
  environment, never argv, a file or output. Without it the sync fails at "read the service
  account token" and prints the `put` line to run.
- **One item per Secret**, title `<service>` (`<service>.<account>` when the account is not `default`; never a `/`,
  which `op://` cannot address), category API Credential, tag `mytokens`,
  and a tag `mytokens-digest-<hash>` of what the item holds. The Description is the notes. Every
  Field is a **concealed** field, labelled by the Field's label (a bare value: `value`). The
  store does not record which Fields came from `--set`, so none is written as plain text: the
  safe side.
- **Values go to `op` on stdin** as an item template (`op item create|edit --template
  /dev/stdin`), never argv.
- **Exactly the `server`-level Secrets.** `op item list --vault <v> --tags mytokens` shows what
  mytokens tagged. An item is the sync's own only with a `mytokens-digest-*` tag; one whose Secret is
  gone or no longer `server`-level (or a second item of one title) is archived (`op item delete
  --archive`, recoverable in 1Password). A `mytokens`-tagged item without a digest tag (copied by
  hand) whose title is wanted is **taken over**: edited in place, same id and category, and it then
  carries the digest tag. One whose title is wanted by no Secret, and items without the `mytokens`
  tag, are never touched; `onepassword list` says how many such hand-made items a vault holds.
  Two Secrets with one title fail the sync for that vault, naming both, with nothing written. An item whose digest tag matches is left alone, so a
  second sync with nothing changed makes no write — only the one `item list`.
- **Background Sync (ADR-0016)** syncs every listed vault after the hosts, each on its own; a
  vault's status lives in the same per-Mac state under `1password:<vault>`; a vault failing 24
  hours is pushed through Bark like a host. A `put`/`rm` of a `server`-level Secret kicks the
  agent, which covers vaults too.
- **A server reads** `op read "op://<vault>/<title>/<Label>"` with its own read-only
  service account.

## Considered Options

- **A new level (`vault`).** Rejected: `server` already means "may leave my personal Macs".
- **Store a digest as a field, or read every item to compare.** Rejected: a tag shows in one
  `item list`, so an unchanged sync reads no values.
- **Delete rather than archive.** Rejected: archive is undone in 1Password; this is a write to
  someone's vault.

## Consequences

- `CONTEXT.md` gains **1Password vault** and **Vault list**; README, the skill and `usage` change.
- The vault holds every `server`-level value in clear to whoever the vault is shared with: that
  is the point, and the human chooses the vault.
- `op` must be on the personal Mac's PATH (the agent's PATH has Homebrew's).
- Not verified here: that `op` accepts `--template /dev/stdin`.
