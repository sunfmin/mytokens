# Every Secret carries a level, personal or server; servers hold the server-level ones, pushed from a personal Mac

Status: narrowed by ADR-0012 — `push` became `sync`, which also adopts the Secrets entered on a Server.
ADR-0013 replaces the Server's login keychain with local data-protection keychain items.

Every **Secret** carries a **Level** that says how far it may travel: `personal` (the
default — it stays in the iCloud Keychain on the user's own Macs) or `server` (it may also be
**pushed** to the user's **Servers**). A Server does not sign into iCloud: it holds the
`server`-level Secrets in its own local store — the login keychain — and gets them only by a
push from a personal Mac (`mytokens push <host>`). Because a Server has no desktop to pop the
input popup on, `put` also collects values in the terminal (so it works over SSH) and through a
one-time web link.

## Context

mytokens was built for one person's Macs: every Secret lives in the iCloud Keychain under our
access group (ADR-0001) and syncs to each Mac where the Helper is installed. The user also
runs servers — headless Macs reached over SSH and the tailnet — whose jobs need some of the
same Secrets (a deploy token, an API key for a long-running agent). Felix's decisions
(sunfmin/control, 2026-11-03):

- Servers **do not sign into iCloud**. Signing a server into the user's Apple ID would put
  *every* Secret (and every other iCloud item) on a machine that others may administer or that
  runs unattended.
- **Each Secret carries a level**, so which Secrets may leave the user's own Macs is a fact
  of the Secret, set where it is stored, not a list kept somewhere else.
- **Every `server`-level Secret is pushed** to the servers; there is no per-server selection.
- **Input works from a terminal over SSH and from a one-time web link**, not only from the
  desktop popup.

## Decision

- **Level.** One of `personal` or `server`, set by `mytokens put <service> --level
  personal|server`. Like every `put` (ADR-0009) it upserts: a `put` without `--level` keeps
  the stored level, a new Secret without it is `personal`. On an existing Secret, `put
  <service> --level <level>` with no `--set`/`--fields` changes only the metadata — the values
  are kept and no popup appears — so a Secret can be raised to `server` (or lowered back)
  without re-entering it. An unknown level is refused, naming the two allowed values.
- **Storage.** The level lives in the keychain comment JSON beside `kind`, `meta`, `fields` and
  `description` (ADR-0005). A Secret stored before this has no level and reads as `personal`;
  so does any level a build does not know. The default is the one that travels nowhere.
- **Reading it.** `mytokens list` shows each Secret's level after its kind. `mytokens get
  <service> --json` returns the whole Secret with its level: `{"fields": {label: value},
  "level": …}` for labelled Fields, `{"level": …, "value": …}` for the lone unlabelled value.
  The level sits beside the values, never among them, so no Field label can collide with it.
  This replaces ADR-0005's bare `{label: value}` `--json` output, and `--json` on a single
  value now returns JSON rather than being ignored. Bare `get` and `get --field` are unchanged.
- **Servers.** A Mac's role is one local setting (`mytokens host server|personal`, default
  `personal`). On a Server, every command acts on its own local store, the **login keychain**,
  readable while the screen is locked (an unattended server's normal state) — not the iCloud
  Keychain — through the same Helper and `SecretStore` seam. Every Secret stored there is
  `server`-level.
- **Push.** A personal Mac runs `mytokens push <host>`, which makes the Server hold exactly
  its `server`-level Secrets: each whole record (Fields, kind, meta, Description, level) goes
  over `ssh <host>` to `mytokens put --stdin`, values only in the pipe (never argv, the
  environment, a file or printed output). Pushed Secrets carry a pushed mark; a pushed Secret
  no longer `server`-level, or gone, on the personal Mac is removed from the Server, and a
  Secret entered on the Server itself is never touched. A second push changes nothing.
- **Input without a desktop.** With a controlling terminal, `put` reads secret Fields from
  `/dev/tty` with echo off (`--show` Fields echo). With no terminal and no desktop, `put`
  collects values through a one-time link: a page served on the host's tailnet address only,
  behind a fresh 128-bit token, usable once for the one Secret and for 10 minutes. The value
  goes from the browser straight into the Helper — never through the agent or its transcript. The desktop popup stays
  the path when there is a desktop and no terminal — except on a Server, which runs
  unattended: a logged-in desktop there is a screen nobody watches, so a Server goes terminal,
  then link (sunfmin/control#519 found the fleet's agents running in such a session).

## Narrows ADR-0001

ADR-0001 rejects the login keychain for mytokens. That stands for the user's own Macs. On a
**Server** the login keychain *is* the store: a Server does not sign into iCloud, so the
iCloud Keychain is not available there, and local-only is exactly what a Server wants — its
Secrets come from a push, not from sync. Everything else in ADR-0001 is unchanged.

## Considered Options

- **Sign servers into iCloud.** Zero new code — the Helper already syncs. Rejected: it hands
  every Secret, not just the ones a server needs, to a machine the user does not sit at.
- **A per-server allowlist instead of a level.** Rejected: one more list to keep in step with
  the Secrets (a second home for the same fact), and Felix decided every `server`-level Secret
  goes to every server.
- **Put `level` inside the `get --json` field object.** Keeps the old shape. Rejected: a Field
  may be labelled `level` (a Profile's env var, say), and metadata among values is ambiguous.

## Consequences

- `CONTEXT.md` gains **Level**, **Server** and **Push**; its **Login keychain (not used)** entry
  now points here.
- Anything parsing `get --json` reads the values under `fields` (or `value`).
- Built by these sunfmin/control tickets:
  - sunfmin/control#515 — every Secret carries a level (this ADR; `put --level`, `list`, `get --json`).
  - sunfmin/control#516 — `put` reads secret Fields in the terminal, so it works over SSH.
  - sunfmin/control#517 — a Server keeps its Secrets in the login keychain, readable while its screen is locked.
  - sunfmin/control#518 — `push <host>` makes a Server hold exactly the `server`-level Secrets.
  - sunfmin/control#519 — with no terminal or desktop, `put` collects values through a one-time tailnet link.
