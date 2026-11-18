---
name: mytokens
description: >-
  Store and retrieve API tokens, keys, and secrets from the macOS Keychain, and
  auto-supply them when authenticating to an external service. Consult this BEFORE
  asking the user for any credential, or assuming a token/key is unavailable — for
  Cloudflare, GitHub, OpenAI, databases, and the like. Also mints short-lived,
  least-privilege Cloudflare child tokens from a stored parent token, and stores
  **Profiles** — named env-var bundles emitted as shell `export` lines — to hold a
  project's environment variables (one Profile per project, instead of a `.env` file)
  or to point a tool (e.g. Claude Code) at a different API provider, endpoint, and
  model. Use it whenever a project needs environment variables set, read, or added,
  and before creating any new token, key, or deploy key.
---

# mytokens

`mytokens` is a signed macOS Helper that keeps machine-usable **Secrets** in the iCloud
Keychain and hands them to you on demand. It is **service-agnostic**: it only stores and
returns values. Anything service-specific (e.g. Cloudflare token minting) is something
**you** do at runtime with the returned value — see the Cloudflare example below.

A Secret is readable while the screen is locked (SSH, background jobs), once the Mac has
been unlocked since it booted. `keychain is locked (interaction not allowed)` means it has
not been since a reboot: the human must log in once (at the Mac or over Screen Sharing).

## Install (do this before first use)

The `mytokens` CLI is a separate signed app, not part of this skill folder. Before running
any command below, make sure it's installed — if it isn't, install it from the bundled
script (runs from this skill's directory):

```sh
command -v mytokens >/dev/null 2>&1 || bash scripts/install.sh
```

`scripts/install.sh` downloads the latest **notarized** release from GitHub, installs
`MyTokens.app` into `~/Applications`, symlinks `~/.local/bin/mytokens`, and runs `selftest`
to confirm the keychain entitlement works on this Mac. macOS only. If the user would rather
build and sign it themselves (their own Apple identity), point them at the repo README's
"Build from source" section instead. If `~/.local/bin` isn't on `PATH`, tell the user to add
it (the script prints the line).

## When to use this (auto-invocation)

Before you ask the user for a credential, or conclude that a token/key isn't available, **check `mytokens` first**:

```sh
mytokens list                 # what's stored (services/accounts/kind; never values)
mytokens get <service>        # the raw value on stdout; non-zero exit if absent
```

**Look before minting.** Before you *create* any credential — a new API token, an API key, an
SSH deploy key, a Child token — run `mytokens list` and read the descriptions: reuse a stored
Secret or Profile that fits the job, and create a new one only when none does.

If the Service has a Secret, use it. If `get` exits non-zero, the Secret isn't stored yet — offer to `put` it (secret values pop a secure popup and never pass through you; non-secret values you can pass on the CLI with `--set`):

```sh
mytokens put <service> --description "<what it's for>" [--account <label>] [--kind static|parent|profile] [--meta '<json>']
# A credential with several parts (key + secret, user + password) → one popup:
mytokens put aws --description "CI deploy: S3 uploads" --fields "Access Key ID","Secret Access Key" --show "Access Key ID"
```

**Always pass `--description`** — a short note of what the Secret is for. A *later* run sees it in `list` and knows the Secret's purpose, and the human sees it in the popup as the reason the dialog appeared.

Where `put` asks: in the terminal when the human runs it in one (hidden input; works over `ssh -t`), else the desktop popup (never on a `server`: nobody watches its screen), else a **one-time tailnet link**. With the link, `put` prints `mytokens: open this link …` and the URL on stderr, then **blocks** until the human submits it (exit 0, `stored …`) or it expires after 10 minutes (non-zero, nothing stored). So run that `put` in the background, read the link from its output as soon as it appears, and hand the link to the human (e.g. a phone push) — the value never passes through you. Only with no terminal, no desktop and no tailnet does `put` store nothing at once and print the exact command — hand that line to the human to run in their own `ssh -t` session.

**On a Server** (`mytokens host` prints `server`), a missing Secret is different: a Server holds
only the `server`-level Secrets Synced from the human's personal Macs, so do **not** `put` it there
and never ask for the value in chat. `get`/`env` exit non-zero and print why, with the exact line
to run on a personal Mac (`mytokens put <service> --level server`, then `mytokens sync <host>`);
with a `bark` Secret on the Server they also push that to the human's phone (once an hour per
Secret). Relay that message to the human verbatim, and stop or carry on without the Secret until
it arrives.

## Consent contract

- **Reading/using a stored Secret is silent.** The user storing it is standing authorization to use it — don't ask.
- **Announce, but don't gate, outward-facing writes.** Before minting or revoking a token (a write to the service's account), say what you're about to do (e.g. "minting a 24h DNS-edit Cloudflare child token"), then proceed without waiting for approval.
- **When a Secret is missing, `put` it** via `mytokens put <service>` (secret fields pop the dialog) rather than aborting the task — except on a Server, where you relay the miss message instead (above).

## Consumption hygiene

The value is plaintext once `get` returns it (acceptable on this trusted machine — see ADR-0002), so don't make it worse:

- Consume inline: `curl -H "Authorization: Bearer $(mytokens get openai)" …` — don't assign it to a variable you later `echo`.
- Never `echo`/`print` a Secret, and never run the surrounding commands under `set -x`.

## Commands

| Command | Purpose |
|---|---|
| `mytokens put <service> --description "<text>" [--account L] [--kind static\|parent\|profile] [--meta JSON] [--level personal\|server]` | Upsert. No `--set`/`--fields` ⇒ one bare value via popup. |
| `mytokens put <service> --level personal\|server` | On an existing Secret: change only its Level — no popup, values kept. |
| `mytokens put <service> --set "<NAME>=<value>" …` | Upsert non-secret field(s) from the CLI — **no popup**. Repeatable. |
| `mytokens put <service> --fields "<A>","<B>" [--show "<A>"]` | Upsert secret field(s) via one popup; masked unless `--show`. |
| `<command> \| mytokens put <service> --field-from-stdin "<A>"` | Upsert one secret field from a command's output — **no popup**. Only for a value a command makes (see below). |
| `<command> \| mytokens put <service> --field-from-stdin "<A>" --list` | Upsert a **list** field: stdin is a JSON array of flat string-valued records (`[{"host":"db1","password":"…"},…]`). Same rules as above. |
| `mytokens get <service> [--account L]` | Raw value to stdout; non-zero exit if absent. |
| `mytokens get <service> --field "<A>"` / `--json` | One field's raw value / the whole Secret as JSON: `{"fields":{…},"level":…}` (or `{"level":…,"value":…}` for a lone value). |
| `mytokens env <service> [--account L]` | A Profile's env vars as shell `export` lines for `eval`. Errors on a non-Profile. |
| `mytokens list` | Stored services/accounts/kind/level/description/fields/meta; never values. |
| `mytokens rm <service> [--account L]` | Delete the whole Secret. Whole-replace = `rm` then `put`. |
| `mytokens selftest` | Real-keychain round-trip sanity check. |
| `mytokens sync <host>` | On a personal Mac, over SSH (values only in the pipes): first **adopt** each Secret entered on the Server `<host>` — store it here, whole, `server`-level, Description noting the Server and date — then make the Server hold exactly the `server`-level Secrets. Prints `adopted`/`added`/`updated`/`removed`/`conflict` names, or `no changes`. A Secret the Server entered and later changed in place is `adopted` again: the copy here follows it. A same-name Secret here not adopted from that Server, or one changed on both sides since the last `sync`, is a `conflict`: neither side changes, exit non-zero — leave it for the human. `push` is gone. |
| `mytokens server add <host>` | On a personal Mac, over SSH: install or upgrade MyTokens on `<host>` (nothing needed there first), set it `server`, run `selftest` there, `sync`, and add it to the **Server list** every personal Mac shares. A failure names its step and leaves the host off the list. On a listed host it repairs (same steps, nothing else changes). |
| `mytokens server list` / `mytokens server rm <host>` | Print the Server list (host names only). `rm` syncs `<host>` to hold no Secrets — adopting what was entered there first, stopping on a conflict — then takes it off the list. All three are refused on a Server. |
| `mytokens server sync` / `server pause` / `server resume` | **Background Sync** (personal Mac only): its launchd agent runs `server sync` every 15 minutes and right after a `put`/`rm` changes a `server`-level Secret here. For each listed host, it upgrades MyTokens there when it is missing or older, then Syncs. Hosts are independent. `server list` shows each host's last Sync, or its failed step, error and fix. A host failing 24 h is pushed through Bark once a day (needs a `bark` Secret here). `pause`/`resume` apply to this Mac only. After a `put --level server`, you need not run `sync` yourself; run `mytokens server sync` only when it must happen now. |
| `mytokens onepassword add <vault>` / `list` / `rm <vault>` | On a personal Mac: make the 1Password **vault** hold exactly the `server`-level Secrets (one item each, titled `<service>`, or `<service>.<account>` for a non-default account, Description as notes, every Field concealed, the metadata in a `mytokens` section, tag `mytokens`), written with the service account token stored as the personal Secret `1password-service-account` (`mytokens put 1password-service-account`; a missing token fails naming that `put`). Read a field with `op read "op://<vault>/<title>/<FieldId>"` and a list record with `op://<vault>/<title>/<ListId>.<i>/<key>`: `op://` takes only letters, digits, space, `_`, `-`, `.`, `=`, so each field and record has an id (its label with every other character `_`, a collision numbered `_2`; `Access Key ID` → `Access_Key_ID`), listed label → id in the item's `mytokens` section (`op://<vault>/<title>/mytokens/ids`). A sync never writes an unchanged item and defers a write past the service account's budget (`deferred …` in `list`). Background Sync keeps listed vaults current; `list` shows each one's last sync or failure. `rm` archives what mytokens made there and unlists it. The vault is two-way: a value may be entered in 1Password's `devbox` vault (any item category; the title is the service, `<service>.<account>` for an account) and appears in mytokens as a `server`-level Secret on the next sync (Background Sync, every 15 min; or `mytokens server sync`); a change made there flows back too. Items that can't be mapped without loss, and changes made on both sides, are listed by `onepassword list` for the human to decide. A hand-made `mytokens`-tagged item with a wanted title is taken over in place. A machine that is not a Mac running mytokens reads it with `op` and its own read-only service account (the token is `OP_SERVICE_ACCOUNT_TOKEN`). The item holds the whole Secret: Fields are plain top-level concealed fields, a list Field is one section per record `<Label> [<i>]` (ADR-0020), and service, account, kind, level, meta and the Fields' order are in the `mytokens` section (ADR-0022). One text Field: `op read "op://<vault>/<title>/<Label>"`. Everything else with the `jq` programs in `skills/mytokens/op/` (`P=<repo>/skills/mytokens/op`; `item() { op item get "<title>" --vault <v> --format json; }`): `item | jq -cSj -L $P -f $P/secret.jq` = `mytokens get <service> --json`; `item | jq -rj -L $P -f $P/env.jq` = `mytokens env <service>` (a Profile); `item | jq -cSj -L $P --arg label <Label> -f $P/field.jq` = `mytokens get <service> --field <Label>` (a list Field: its JSON array). `op read` cannot address a list record by its section label. What each item is for: `op item list --vault <v> --format json | jq -r '.[] | "\(.title)\t\(.additional_information)"'` (the start of the Description), in full `op item get <title> --vault <v> --fields notesPlain`. Refused on a Server. |
| `mytokens host [personal\|server]` | Print this Mac's role, or set it. On a `server` every command acts on local, non-synchronizable keychain items (readable over SSH after the first unlock since boot) and every Secret stored is `server`-level. |

**`put` upserts** (ADR-0009): it updates/inserts the fields you name and **keeps the rest**, so `put svc --set MODEL=…` changes one field and `put svc --fields TOKEN` rotates one secret — the others are untouched. Works the same for a lone value, a composite credential, or a Profile. There is no whole-replace; to rebuild (or drop a stale field), `rm` then `put`.

`--level` says how far a Secret may travel (ADR-0010): `personal` (default — only the user's own
Macs) or `server` (also held by the user's Servers, via `sync`). A Secret entered on a Server becomes
a `server`-level Secret here at the next `sync`. On a Server, `put` into a Secret `sync` brought
there from a personal Mac is refused (exit 64, nothing stored): change it on a personal Mac, or put the Server's own
values in a Secret of their own there, which the next `sync` adopts. A Secret entered on the Server stays changeable
there after adoption — rotate it in place; never start a `name-2`. A `put` without `--level` keeps the stored
level. Mark a Secret `server` only when a job on a Server needs it.

`--account` lets one Service hold several Secrets (`cloudflare/personal` vs `cloudflare/work`).
`--description` records what a Secret is for (shown by `list` and in the popup) — **always set it** when you first `put` a Secret; it's how a later run recalls its purpose (a merge keeps it if you don't repeat it). It's prose for a reader, distinct from `--meta` (structured machine data like a Cloudflare `account_id`).

### Multi-field credentials (ADR-0005)

Some credentials are several values used together — AWS *Access Key ID* + *Secret Access
Key*, a DB *Username* + *Password*. You know the parts (you know the Service), so pass the
field **labels** at `put` time; they're collected in **one** popup and stored as **one**
Secret that deletes as a unit.

- **Create / rotate together**: `mytokens put aws --fields "Access Key ID","Secret Access Key" --show "Access Key ID"`.
  Labels are comma-separated; every named field is required; `--show` reveals non-secret fields
  (identifiers) so the user can verify a paste — everything else is masked. Naming both fields
  in one `put` rotates them atomically. `--kind parent` is single-value and can't take `--fields`.
- **Change the kind** of an existing Secret in place: `mytokens put <service> --kind profile|static` keeps values, Description and level (a Profile needs every label to be an env-var name; a Parent needs `rm` first). An item adopted from a 1Password vault comes in as `static` with a hand-made item's section fields moved to the top level (`op://<vault>/<title>/api key`, not `.../extra/api key`); make it a Profile this way.
- **Update one field** without touching the rest (ADR-0009): `mytokens put aws --fields "Secret Access Key"`
  re-pops just that field; the Access Key ID is left as-is. Non-secret parts can go via
  `--set` instead of the popup, e.g. `mytokens put db --set "Username=svc_ci"`.
- **A value a command makes** — a `.p12` from `security export`, a password from `openssl rand` —
  is piped straight in, with no popup: `openssl rand -base64 32 | mytokens put dev-id
  --field-from-stdin "P12 password"` (ADR-0021). All of stdin is the one field's value (no length
  limit; one trailing newline stripped; base64 any binary). It upserts like `--fields` and
  combines with `--set`/`--description`/`--level`; one call per field. **Use it only when a
  command generates the value and pipes it in directly.** Never use it to relay a value the
  human typed or pasted into chat, and never `echo`/`printf` a known secret into it. A value
  the human knows goes through `--fields` (terminal, popup or link). Never write the value
  to a file or a variable first. It is refused when stdin is a terminal or empty.
- **Get one field**: `mytokens get aws --field "Secret Access Key"` → that field's raw value
  (the label is the key — quote the spaces). Consume inline, e.g.
  `AWS_SECRET_ACCESS_KEY=$(mytokens get aws --field "Secret Access Key")`.
- **Bare `get`** returns the raw value for a single-field Secret, but **errors** for a
  multi-field one and lists the field labels — use `--field`, or `--json` to dump the whole
  Secret (`{"fields": {label: value}, "level": …}`).
- **`list`** shows the field labels (never values); a list field shows as `Hosts (list, 2 records)`.
- **A list of records** (ADR-0019): when a credential is a set of same-shaped records — one login
  per DB host, one token per runner — store them as one **list** field instead of numbered
  fields: `<command> | mytokens put db --field-from-stdin "Hosts" --list`, stdin a JSON array of
  flat objects whose keys are non-empty and whose values are all strings. Any other shape is
  refused before anything is stored. The `--field-from-stdin` rules above apply: only a list a
  command makes. `get --field Hosts` prints the array as compact JSON (pipe it to `jq`), and
  `get --json` puts the array itself under `fields`. `--fields`/`--set`/popup/link refuse a list
  field. A Profile cannot hold one, because `env` emits one string per variable.

### One Profile per project

A project's environment variables — secret or not — live in **one Profile named after the
project** (e.g. `mytokens` for this repo). Run the project's commands with it loaded, scoped to
that one command:

```sh
(eval "$(mytokens env <project>)"; <cmd>)
```

- **Never** put a project's env vars in a `.env` file, a shell rc (`~/.zshrc`, `~/.zshenv`, …),
  or the repo. If you find them there, put them into the Profile and tell the user what to delete.
- **Add or change** a var with `put`, which merges: `mytokens put <project> --set "NAME=value"`
  for a non-secret value, `mytokens put <project> --fields "NAME"` for a secret one (the popup —
  the value never passes through you). Create the Profile on its first var with
  `--kind profile --description "<project>: <what it runs>"`.
- **See what it holds**: `mytokens list` shows each Profile's var names, never the values.

### Profiles: point a tool at another provider (ADR-0008)

A **Profile** is a named bundle of environment variables — a provider's endpoint, model, and
token — stored as one item and emitted as shell `export` lines. Use it to launch a tool
(Claude Code is the motivating case) against a *different* API provider. Name such a Profile
by **provider** (`glm`), not by tool — the same Profile then serves any tool that reads those
vars. (A project's own vars go in the project's Profile, above.)

- **Create** (`--kind profile`): pass the non-secret config on the CLI with `--set`, and the
  secret token via `--fields` (the one popup). You know the provider, so you supply the env-var
  **names**; labels must be valid shell identifiers, validated at `put`:
  ```sh
  mytokens put glm --kind profile --description "Claude Code → GLM" \
    --set "ANTHROPIC_BASE_URL=https://open.bigmodel.cn/api/anthropic" \
    --set "ANTHROPIC_MODEL=glm-4.6" \
    --fields "ANTHROPIC_AUTH_TOKEN"
  ```
- **Update one var**, leaving the rest — `put` merges:
  ```sh
  mytokens put glm --set "ANTHROPIC_MODEL=glm-4.6-pro"   # change the model only, no popup
  mytokens put glm --fields "ANTHROPIC_AUTH_TOKEN"       # rotate the token only (popup)
  ```
- **Load & launch** — `env` prints `export NAME='VALUE'` lines (safely single-quoted); `eval`
  them so the tool you launch in that shell inherits them:
  ```sh
  eval "$(mytokens env glm)" && claude       # …or aider, or any Anthropic-compatible tool
  ```
- **Scope to one launch** — a subshell keeps the token out of your interactive shell for the
  rest of the session:
  ```sh
  (eval "$(mytokens env glm)"; claude)
  ```
- `env` **errors on a non-Profile Secret** (it won't emit `export`s from, say, an AWS
  credential), and `list` shows a Profile as `kind=profile` with its env-var names, never values.

## Minting short-lived tokens — Cloudflare as the worked example

This is a **runtime pattern, not a Helper feature**. The same shape applies to any Service
whose API can create scoped tokens: *get the parent → call the service's token API → use the
child → revoke it.* Cloudflare is just the example.

A **Parent token** must actually be able to *create* tokens — don't trust the `--kind parent`
label or the dashboard name. Detect it. Cloudflare has two flavors, on different endpoints:

- **User-owned** token with permission **`User → API Tokens → Edit`** → uses `/user/tokens/*`.
  **Recommended** — this is the standard "create additional tokens" path.
- **Account-owned** token with account API-token **write** → uses `/accounts/{account_id}/tokens/*`.

**Detect mint-capability first (learned the hard way):** an account-scoped *read* token can list
`/accounts` and look like a parent but cannot mint. Probe before relying on it:

```sh
PARENT="$(mytokens get cloudflare)"          # never echo it
API=https://api.cloudflare.com/client/v4

# Is it a USER token? success:true (with id+status) means yes; "Invalid API Token" / code 9109
# means it is account-scoped — switch the paths below to /accounts/$ACCOUNT_ID/tokens.
curl -s -H "Authorization: Bearer $PARENT" "$API/user/tokens/verify"

# Can it CREATE? Read the token's OWN policies — never probe with a POST: Cloudflare accepts an
# empty-policy POST /user/tokens with 200 and really creates a token (seen 2026-09 and 2026-10).
ID=$(curl -s -H "Authorization: Bearer $PARENT" "$API/user/tokens/verify" | jq -r .result.id)
curl -s -H "Authorization: Bearer $PARENT" "$API/user/tokens/$ID" \
  | jq '[.result.policies[] | select(.effect=="allow") | .permission_groups[].name] | index("API Tokens Write") != null'
# false (or an auth error) → NOT a mint-capable Parent. Tell the user to make a USER token with
# "API Tokens: Edit". If you ever did POST a probe, list /user/tokens and DELETE what it made.

# pick minimal permission groups for the task (needs API Tokens *Read*):
curl -s -H "Authorization: Bearer $PARENT" "$API/user/tokens/permission_groups"

# ANNOUNCE: "minting a 24h DNS-edit child for zone <ZONE_ID>", then mint:
EXPIRES=$(date -u -v+24H +%Y-%m-%dT%H:%M:%SZ)     # 24h default (ADR-0004)
RESP=$(curl -s -X POST -H "Authorization: Bearer $PARENT" -H "Content-Type: application/json" \
  "$API/user/tokens" --data @- <<JSON
{ "name": "mytokens-child-dns-edit",
  "policies": [{ "effect": "allow",
    "resources": { "com.cloudflare.api.account.zone.<ZONE_ID>": "*" },
    "permission_groups": [{ "id": "<DNS_WRITE_PG_ID>" }] }],
  "expires_on": "$EXPIRES" }
JSON
)
CHILD=$(echo "$RESP" | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["value"])')
CHILD_ID=$(echo "$RESP" | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["id"])')

# use the Child for the actual work, e.g.:
curl -s -H "Authorization: Bearer $CHILD" "$API/zones/<ZONE_ID>/dns_records"

# ANNOUNCE: "revoking the child token", then revoke (expiry is the backstop):
curl -s -X DELETE -H "Authorization: Bearer $PARENT" "$API/user/tokens/$CHILD_ID"
```

Notes:
- For an **account-owned** Parent, swap every `/user/tokens…` above for `/accounts/$ACCOUNT_ID/tokens…`,
  read the catalog from `/accounts/$ACCOUNT_ID/tokens/permission_groups`, and scope the child to the
  account resource `{"com.cloudflare.api.account.$ACCOUNT_ID":"*"}` (verified working end-to-end).
- Infer the **minimal** permission groups the task needs; the Parent's permissions are the hard ceiling.
- Default Child lifetime is **24h**; honor a `default_ttl_seconds` in the Parent's `--meta` if present.
- Always best-effort `revoke` when done; the short `expires_on` cleans up if you don't.
