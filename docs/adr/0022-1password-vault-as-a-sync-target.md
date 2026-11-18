# A 1Password vault is one more Sync target, two-way, for machines that are not Macs running mytokens

`mytokens onepassword add <vault>` makes a 1Password vault hold exactly this Mac's `server`-level
Secrets, one item each, written with a 1Password **service account**. Background Sync keeps it
current. A Linux box or a CI job reads it with its own read-only service account. It is **two-way**
(mytokens#13): an item added or changed in 1Password is Adopted into mytokens on the next sync; the personal Mac stays the home.

## Context

Felix, 2026-11-18 (control session): 「把里面的数据标记成 server 的，直接导到 1Password 的 service
account」. A Server (ADR-0010) is a Mac running mytokens. Other machines have no mytokens and no
keychain, but can run `op`. The Level `server` already means "may be held by machines other than
my personal Macs", so no new level is introduced: a vault is one more target, with the same rule
as a Server — every `server`-level Secret goes to every target (ADR-0012).

## Decision

- **Glossary: 1Password vault** — a vault named by `onepassword add`, written by Sync. It is
  *not* a Server (nothing runs mytokens there). Like a Server it is an **origin**: what was entered there is Adopted
  (ADR-0012, ADR-0018), see "Two-way" below.
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

- **Two-way (mytokens#13).** Felix, 2026-11-18: 「做成一个同步。如果有人在 op 上面加了的话，也同步进 my tokens。」
  The terms are a Server's (ADR-0012, ADR-0018); every item the sync reads is a `server`-level Secret, and what
  differs is only where the change was made.
  - **Adopt.** An item without a digest tag (not made by mytokens) whose title names no Secret on this Mac is
    stored as a `server`-level Secret, whole, with origin mark `1password:<vault>`, its Description
    `adopted from 1Password vault <v> on <date>` followed by the item's notes; then the item is rewritten
    into mytokens' format (`op item edit`, with tags — a JSON without `tags` wipes them) so it is the sync's own and
    its `op://<vault>/<title>/<Label>` paths are unchanged. A Login's `username` and `password` fields keep their ids
    (they cannot be removed, a second `password` would appear). An adoption cut short (Secret stored, item not
    rewritten) is finished next sync: the Secret's origin is this vault.
  - **Decoding a hand-made item** (`decodeHandMadeItem`, any category): the title is `<service>.<account>` when it
    has exactly one dot, else the whole title is the service and the account `default` (service names contain
    dots, so a title with several dots cannot be split); notes → Description; every non-empty field → a Field
    labelled as in 1Password, concealed or not (empty and null built-ins skipped); sections `<Label> [<i>]` → a
    list Field. Not adopted, reported by name and reason in `onepassword list` (and in the sync's lines): two
    fields of one label, files or a Document, a list and a field of one label, a field with no label, no values.
    Login `urls` and tags are not kept.
  - **Changes flow back.** The sync remembers, per Mac, for each item it owns: the `version` `op item list`
    showed after it last wrote or adopted it, and the digest of what it then held (`VaultMemory`, in the vault's
    status). Same listed version: nothing changed in 1Password, no read, and if the Secret's digest differs the Mac
    changed, so it is written. Another version (or none remembered, or the write did not say): the item is read
    once and compared: same content as the Secret → in sync; Secret unchanged since the last write → the
    change is Adopted (and the item's tag rewritten); item unchanged → the Mac's change is written; both
    changed → **conflict**, neither side changes, shown by `onepassword list` until the human resolves it.
    Fields added in 1Password after the metadata's `order` are kept after the others. An owned item that can no
    longer be read back (metadata deleted) is rewritten from the Secret: the Mac is the home.
  - **Deletions.** A Secret removed or lowered to `personal` → its item archived. An item deleted in the vault
    whose Secret is `server`-level → written again. 1Password lists a new item only ~10 s after `create`, so a
    sync inside that window must not create it again: the title's creation time is remembered for 2 minutes.
  - **Name clash.** An item the sync does not own whose title names a Secret on this Mac that the sync does
    not own (any level) is a **conflict**, not a takeover, except a `mytokens`-tagged item with a wanted title (the
    2026-11-07 hand copies), still taken over in place.
  - **Budget** (measured, op 2.42): a service account may write 100 times an hour; every `create`/`edit`/`delete`
    is a write and every `op` call takes ~2 s. An unchanged vault costs one `item list`; an item is read only when
    its version moved; nothing unchanged is written.
  - `onepassword rm` still adopts nothing. A Server's role is unchanged (mytokens#11).

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
- Checked against real 1Password (mytokens#12, op 2.42.0, vault devbox): with the JSON piped on stdin and **no** `--template`, `op item create` and `op item edit` write bare-value, labelled, list-field and profile items, and `op read` and `skills/mytokens/op/*.jq` read them back. mytokens#10's check of `--template /dev/stdin` was wrong: op 2.42 refuses it with a pipe ("cannot create|edit an item from template and stdin at the same time"). op takes the stdin template only from a pipe, not a `<` file redirect. An `item edit` sent within seconds of the create can get a transient 409 from the server.
