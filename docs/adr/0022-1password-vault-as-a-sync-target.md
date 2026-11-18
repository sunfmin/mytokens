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
  which `op://` cannot address), category Secure Note (`op item list --format json` shows the start of its notes as `additional_information`; an API Credential shows null), tag `mytokens`,
  and a tag `mytokens-digest-<hash>` of what the item holds. The Description is the notes. Every
  Field is a **concealed** top-level field, labelled by the Field's label (a bare value: `value`). The
  store does not record which Fields came from `--set`, so none is written as plain text: the
  safe side. Items made earlier as API Credential are left as they are (a category cannot be edited, and their digest still matches, so the sync does not rewrite them); to get the Description into a list, `op item delete` them and the next sync recreates them as Secure Notes (`op://` references go by title, so they keep working).
- **Values go to `op` on stdin** as an item template (`op item create|edit` with the JSON piped on stdin and no
  `--template`: op 2.42 refuses both together), never argv.
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
- **The item holds the whole Secret, losslessly** (mytokens#10: a server reads its Secrets from the
  vault with `op` alone, so nothing a Secret is may be lost). One mapping, Secret ⇄ item:
  - **Description** → the notes (`notesPlain`); none ⇄ no notes.
  - **Text Field** → a top-level concealed field labelled by the Field; a lone unlabelled value → `value`.
  - **List Field** → one section per record `<Label> [<i>]`, one concealed field per key (ADR-0020).
  - **Everything else** → the section **`mytokens`**, plain (non-concealed) STRING fields: `service`,
    `account` (a title `a.b` is ambiguous: service names contain dots), `kind` (`static` | `parent` |
    `profile`), `level`, `shape` (`bare` for the lone unlabelled value, `fields` for labelled ones, so
    one Field labelled `value` is not a bare value), `order` (the Fields' labels in order, a JSON
    array: a Profile's `export` order, and where a list sits among the text Fields), and `meta` (the
    Meta as compact JSON; absent when there is none). A Field is a list when it has record sections,
    else text.
  - The metadata is in a section, and Fields are top-level, so a Field named `kind` still reads by
    `op read "op://<vault>/<title>/kind"` as the Field; the metadata is `…/<title>/mytokens/kind`
    (checked against real 1Password).
  - `decodeVaultItem` (item JSON → Secret) is the inverse of the template; round trips are tested for
    each shape. The digest tag is taken over the whole item and a format version, so an item written
    by an earlier mapping counts as changed and the next sync rewrites it.
- **A server reads with `op` alone**, with its own read-only service account (`OP_SERVICE_ACCOUNT_TOKEN`),
  and the `jq` programs in `skills/mytokens/op/` (they `include "mytokens"`, so run with `jq -L <dir>`):
  `secret.jq` → the same bytes as `mytokens get <service> --json`; `env.jq` → as `mytokens env
  <service>` (a Profile); `field.jq --arg label <Label>` → as `mytokens get <service> --field <Label>`
  (a list Field is its JSON array). The tests run each against encoded items and compare byte for byte
  with mytokens' own output; `jq` is installed pinned into `$HOME/.local/bin` when the host has none
  (`make jq-install`). One text Field: `op read "op://<vault>/<title>/<Label>"`.

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
- Checked against real 1Password (mytokens#10): `op item create` accepts `--template /dev/stdin`, and the items read back as the template says.
