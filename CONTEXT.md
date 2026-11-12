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
unless explicitly revealed for paste-verification. A secret Field comes from the terminal, the
popup or a One-time link, or — for a value a command makes — piped in on stdin (ADR-0017).
_Avoid_: sub-secret, key/value pair (a Field's label is its identity, not an arbitrary key).

**Description**:
An agent-authored, human-readable note of what a Secret is *for* (e.g. "CI deploy: S3
bucket uploads"), set when a Secret is first `put` and shown by `list` and in the input popup. Its
audience is a *later* agent run recalling a Secret's purpose; the human sees it as the
reason the popup appeared. Optional in the Helper, but the skill mandates the agent always
set one. Distinct from **Meta** (below).
_Avoid_: comment (that is the keychain attribute it happens to be stored in), label.

**Meta**:
Optional structured (JSON) data attached to a Secret for *machine* use — e.g. a Cloudflare
`account_id`, or a `default_ttl_seconds` honored when minting. Set via `--meta`. Distinct
from **Description**, which is prose intent for a reader, not data for a program.

**Service**:
A target API or tool that a Secret authenticates to — or, for a Profile, the provider a
tool is pointed at — identified by a stable slug (`cloudflare`, `github`, `openai`, `glm`,
…). The slug is how Claude looks a Secret or Profile up. The Helper treats every Service
uniformly — service-specific behavior (e.g. Cloudflare minting) lives in Claude's runtime
usage and the skill's recipes, **not** in the Helper (ADR-0004), with one exception: a Server pushes its own **Misses** through Bark (ADR-0014).

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

**Profile**:
A named bundle of environment variables — typically a target API's endpoint, model, and
token — used to point a tool at a provider (e.g. running Claude Code against a different
API). `mytokens env <service>` emits it as shell `export` lines to `eval`, so any tool
launched in that shell inherits them. Unlike a Secret, a Profile is **not** a single
credential: it bundles secret and non-secret config that are used together. Each variable is
one **Field** whose label is the environment-variable name. Two uses: a **provider Profile**
named by provider (`glm`) points a tool elsewhere; a **project Profile** named by project holds
all of one project's environment variables, which never go in a `.env` file, a shell rc, or the repo.
_Avoid_: environment (too generic), config set, env file.

**Level**:
How far a Secret may travel: `personal` (the default — it stays in the iCloud Keychain on
the user's own Macs) or `server` (it may also be held by the user's **Servers**, by **Sync**). Set
by `put --level`; a Secret stored before levels existed reads as `personal` (ADR-0010).
_Avoid_: scope (that is a Child token's permissions), visibility, tier.

**Server**:
A Mac of the user's that runs unattended (reached over SSH / the tailnet) and does **not**
sign into iCloud. It holds only `server`-level Secrets, in local, non-synchronizable keychain
items, received by **Sync** or entered on it directly — and a Secret entered on it is **Adopted**
by the next Sync (ADR-0010, ADR-0012, ADR-0013). The other Macs are **personal Macs**.
_Avoid_: host (the generic machine word; `sync <host>` names one), remote.

**Sync**:
To bring a personal Mac and one Server into agreement, the personal Mac the home of every
Secret on it: `mytokens sync <host>`, over SSH, first **Adopts** the Secrets entered on the
Server, then makes the Server hold exactly the personal Mac's `server`-level Secrets — removing
ones it pushed earlier that are gone or no longer `server`-level (ADR-0012). The only way a
Secret reaches a Server other than being entered on it. A Secret's pushed mark says the Server
got it from a personal Mac.
_Avoid_: push (the old name of this command), two-way sync (each Secret has one home), deploy, copy.

**Server list**:
The hosts set up with `mytokens server add <host>`, kept on the personal Macs as one
synchronizable item in mytokens' access group — so iCloud Keychain sync gives every personal Mac
the same list. Not a Secret (`list` does not show it) and nothing secret: host names only. Only a
host named by `server add` is on it; nothing is discovered from the tailnet. `server rm <host>`
Syncs the host to hold no Secrets, then takes it off. Background Sync keeps every listed Server
current (ADR-0015).
_Avoid_: fleet, inventory, known hosts (that is ssh's file).

**Background Sync**:
What each personal Mac's launchd agent does without being asked. Every 15 minutes, and right after
a command there changes a `server`-level Secret, it Syncs every host on the **Server list**,
first upgrading MyTokens there when it is missing or older. Each host is Synced on its own.
`server list` shows when each host last Synced and why it fails. A host failing for 24 hours
straight is reported through Bark once a day. `server pause` / `resume` turn it off and on for
one Mac. It never runs on a Server (ADR-0016).
_Avoid_: auto-push, cron, daemon (say which).

**Adopt**:
What Sync does with a Secret entered on a Server: store it on the personal Mac, whole, as a
`server`-level Secret whose Description notes the Server and date, and mark it pushed on the
Server — so from then on the personal Mac is its home. A Secret of the same name already on the
personal Mac, at any level, is a **conflict**: neither side changes, and the human decides.
_Avoid_: import, pull, merge.

**Miss**:
A job on a Server asking (`get`, `env`) for a Secret the Server does not hold. Instead of only
failing, the Server says why, names the `put <service> --level server` line to run on a personal
Mac and the Sync that brings it, and pushes the same through Bark with its own `bark` Secret — at
most once per Secret per Server per hour (ADR-0014). On a personal Mac a missing Secret is just absent.
_Avoid_: not found, error (say which).

**One-time link**:
How `put` collects a Secret's values where no terminal or watched desktop reaches the human: a
page served on the Mac's tailnet address only, behind a fresh 128-bit token, good for one
submission of that one Secret within 10 minutes. `put` prints it; delivering it (e.g. a phone
push) is the caller's business. The values go from the browser straight into the Helper (ADR-0010).
_Avoid_: magic link, share link, URL (say which link).

**Password (out of scope)**:
A human-facing web login (username + website + password) of the kind Passwords.app
autofills in a browser. Explicitly NOT managed by this skill.

## Storage

**iCloud Keychain**:
The macOS data-protection keychain that backs Apple Passwords; iCloud Keychain sync carries
it across a user's Apple devices. mytokens stores every Secret here, under its **own access
group**, via the Helper. iCloud Keychain sync therefore carries the items to the user's Macs
where the Helper is installed, but they do NOT appear in the Passwords.app list (see ADR-0001). A Secret there is readable
while the screen is locked, once the Mac has been unlocked since it booted (ADR-0011).
_Avoid_: "the keychain" (ambiguous), "Apple Passwords vault" (we are not in its list).

**Helper**:
The code-signed Swift binary (Apple Developer identity + `keychain-access-groups`
entitlement) that is the **sole** read/write path to mytokens' keychain items.
The `/usr/bin/security` CLI and unsigned scripts cannot substitute — they get
`errSecMissingEntitlement` (-34018) or cannot see the data-protection keychain at all.
_Avoid_: "the script", "the CLI" (reserve "CLI" for the user-facing `mytokens` command).

**Login keychain (not used)**:
The legacy, local-only `login.keychain-db` that `/usr/bin/security` reads/writes. mytokens does
NOT use it on personal Macs or Servers; a Server uses local, non-synchronizable items in the
data-protection keychain instead (ADR-0013 amends ADR-0010).

**Passwords.app (not a storage target)**:
Apple's GUI vault. mytokens Secrets are NOT listed here — making third-party tokens
appear there would require Associated Domains + an AASA file on each service's domain,
which we don't control (ADR-0001).
