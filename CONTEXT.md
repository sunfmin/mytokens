# mytokens

A Claude Code skill for securely storing **machine-usable secrets** on macOS and
auto-injecting them into CLI/API calls — so Claude can, e.g., fetch a Cloudflare
API token at call time without the value ever touching the conversation transcript.

## Language

**Secret**:
A machine-usable credential — an API token, API key, or connection string — that
Claude retrieves and injects into a shell command at call time. A Secret has one or
more named **Fields**; the common case is a single Field (a lone token), which behaves
as one value. A Secret is stored as one keychain item and rotated, listed, and removed
as a unit. In scope for this skill.
_Avoid_: Password (reserve that word for human-facing web logins, which are out of scope).

**Field**:
A labeled value inside a Secret. Most Secrets have exactly one (the token itself);
composite credentials have several that belong together and rotate as a unit — e.g.
AWS *Access Key ID* + *Secret Access Key*, or a database *Username* + *Password*. A
Field is addressed by its **label** (the label is the key), and is masked on input
unless explicitly revealed for paste-verification.
_Avoid_: sub-secret, key/value pair (a Field's label is its identity, not an arbitrary key).

**Description**:
An agent-authored, human-readable note of what a Secret is *for* (e.g. "CI deploy: S3
bucket uploads"), set at `add` time and shown by `list` and in the input popup. Its
audience is a *later* agent run recalling a Secret's purpose; the human sees it as the
reason the popup appeared. Optional in the Helper, but the skill mandates the agent always
set one. Distinct from **Meta** (below).
_Avoid_: comment (that is the keychain attribute it happens to be stored in), label.

**Meta**:
Optional structured (JSON) data attached to a Secret for *machine* use — e.g. a Cloudflare
`account_id`, or a `default_ttl_seconds` honored when minting. Set via `--meta`. Distinct
from **Description**, which is prose intent for a reader, not data for a program.

**Service**:
A target API or tool that a Secret authenticates to, identified by a stable slug
(`cloudflare`, `github`, `openai`, …). The slug is how Claude looks a Secret up. The Helper
treats every Service uniformly — service-specific behavior (e.g. Cloudflare minting) lives in
Claude's runtime usage and the skill's recipes, **not** in the Helper (ADR-0004).

**Parent token**:
A stored Secret that holds permission to *create other tokens* on its Service (e.g. a
Cloudflare token with "API Tokens: Edit"). Never used to perform tasks directly — only to
mint Child tokens. Parent-ness is **detected** from the token's actual permissions when it
is added, not declared by hand.
_Avoid_: root token, master token.

**Child token**:
A short-lived, narrowly-scoped token minted on demand from a Parent token for a single
unit of work. Never stored; deleted or expired right after use.
_Avoid_: scoped token (use as adjective only).

**Mint**:
To create a Child token from a Parent token by calling the Service's token-creation API.

**Password (out of scope)**:
A human-facing web login (username + website + password) of the kind Passwords.app
autofills in a browser. Explicitly NOT managed by this skill.

## Storage

**iCloud Keychain**:
The macOS data-protection keychain that syncs across a user's Apple devices and backs
Apple Passwords. mytokens stores every Secret here, under its **own access group**, via
the Helper. Items therefore sync across the user's Macs (where the Helper is installed)
but do NOT appear in the Passwords.app list (see ADR-0001).
_Avoid_: "the keychain" (ambiguous), "Apple Passwords vault" (we are not in its list).

**Helper**:
The code-signed Swift binary (Apple Developer identity + `keychain-access-groups`
entitlement) that is the **sole** read/write path to the iCloud Keychain for this skill.
The `/usr/bin/security` CLI and unsigned scripts cannot substitute — they get
`errSecMissingEntitlement` (-34018) or cannot see the iCloud Keychain at all.
_Avoid_: "the script", "the CLI" (reserve "CLI" for the user-facing `mytokens` command).

**Login keychain (not used)**:
The legacy, local-only `login.keychain-db` that `/usr/bin/security` reads/writes. Does
not sync. mytokens deliberately does NOT use it (ADR-0001).

**Passwords.app (not a storage target)**:
Apple's GUI vault. mytokens Secrets are NOT listed here — making third-party tokens
appear there would require Associated Domains + an AASA file on each service's domain,
which we don't control (ADR-0001).
