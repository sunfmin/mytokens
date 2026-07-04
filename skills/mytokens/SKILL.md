---
name: mytokens
description: >-
  Store and retrieve API tokens, keys, and secrets from the macOS Keychain, and
  auto-supply them when authenticating to an external service. Consult this BEFORE
  asking the user for any credential, or assuming a token/key is unavailable — for
  Cloudflare, GitHub, OpenAI, databases, and the like. Also mints short-lived,
  least-privilege Cloudflare child tokens from a stored parent token, and stores
  **Profiles** — named env-var bundles emitted as shell `export` lines — to point a
  tool (e.g. Claude Code) at a different API provider, endpoint, and model.
---

# mytokens

`mytokens` is a signed macOS Helper that keeps machine-usable **Secrets** in the iCloud
Keychain and hands them to you on demand. It is **service-agnostic**: it only stores and
returns values. Anything service-specific (e.g. Cloudflare token minting) is something
**you** do at runtime with the returned value — see the Cloudflare example below.

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

If the Service has a Secret, use it. If `get` exits non-zero, the Secret isn't stored yet — offer to `put` it (secret values pop a secure popup and never pass through you; non-secret values you can pass on the CLI with `--set`):

```sh
mytokens put <service> --description "<what it's for>" [--account <label>] [--kind static|parent] [--meta '<json>']
# A credential with several parts (key + secret, user + password) → one popup:
mytokens put aws --description "CI deploy: S3 uploads" --fields "Access Key ID","Secret Access Key" --show "Access Key ID"
```

**Always pass `--description`** — a short note of what the Secret is for. A *later* run sees it in `list` and knows the Secret's purpose, and the human sees it in the popup as the reason the dialog appeared.

## Consent contract

- **Reading/using a stored Secret is silent.** The user storing it is standing authorization to use it — don't ask.
- **Announce, but don't gate, outward-facing writes.** Before minting or revoking a token (a write to the service's account), say what you're about to do (e.g. "minting a 24h DNS-edit Cloudflare child token"), then proceed without waiting for approval.
- **When a Secret is missing, `put` it** via `mytokens put <service>` (secret fields pop the dialog) rather than aborting the task.

## Consumption hygiene

The value is plaintext once `get` returns it (acceptable on this trusted machine — see ADR-0002), so don't make it worse:

- Consume inline: `curl -H "Authorization: Bearer $(mytokens get openai)" …` — don't assign it to a variable you later `echo`.
- Never `echo`/`print` a Secret, and never run the surrounding commands under `set -x`.

## Commands

| Command | Purpose |
|---|---|
| `mytokens put <service> --description "<text>" [--account L] [--kind static\|parent\|profile] [--meta JSON]` | Upsert. No `--set`/`--fields` ⇒ one bare value via popup. |
| `mytokens put <service> --set "<NAME>=<value>" …` | Upsert non-secret field(s) from the CLI — **no popup**. Repeatable. |
| `mytokens put <service> --fields "<A>","<B>" [--show "<A>"]` | Upsert secret field(s) via one popup; masked unless `--show`. |
| `mytokens get <service> [--account L]` | Raw value to stdout; non-zero exit if absent. |
| `mytokens get <service> --field "<A>"` / `--json` | One field's raw value / the whole field object as JSON. |
| `mytokens env <service> [--account L]` | A Profile's env vars as shell `export` lines for `eval`. Errors on a non-Profile. |
| `mytokens list` | Stored services/accounts/kind/description/fields/meta; never values. |
| `mytokens rm <service> [--account L]` | Delete the whole Secret. Whole-replace = `rm` then `put`. |
| `mytokens selftest` | Real-keychain round-trip sanity check. |

**`put` upserts** (ADR-0009): it updates/inserts the fields you name and **keeps the rest**, so `put svc --set MODEL=…` changes one field and `put svc --fields TOKEN` rotates one secret — the others are untouched. Works the same for a lone value, a composite credential, or a Profile. There is no whole-replace; to rebuild (or drop a stale field), `rm` then `put`.

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
- **Update one field** without touching the rest (ADR-0009): `mytokens put aws --fields "Secret Access Key"`
  re-pops just that field; the Access Key ID is left as-is. Non-secret parts can go via
  `--set` instead of the popup, e.g. `mytokens put db --set "Username=svc_ci"`.
- **Get one field**: `mytokens get aws --field "Secret Access Key"` → that field's raw value
  (the label is the key — quote the spaces). Consume inline, e.g.
  `AWS_SECRET_ACCESS_KEY=$(mytokens get aws --field "Secret Access Key")`.
- **Bare `get`** returns the raw value for a single-field Secret, but **errors** for a
  multi-field one and lists the field labels — use `--field`, or `--json` to dump the whole
  `{label: value}` object.
- **`list`** shows the field labels (never values).

### Profiles: point a tool at another provider (ADR-0008)

A **Profile** is a named bundle of environment variables — a provider's endpoint, model, and
token — stored as one item and emitted as shell `export` lines. Use it to launch a tool
(Claude Code is the motivating case) against a *different* API provider. Name a Profile by
**provider** (`glm`), not by tool — the same Profile then serves any tool that reads those vars.

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

# Can it CREATE? An empty-policy POST returns 400 (CAN create) vs 403/code 9109 (CANNOT).
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "Authorization: Bearer $PARENT" \
  -H "Content-Type: application/json" "$API/user/tokens" --data '{"name":"probe","policies":[]}'
# 403 → NOT a mint-capable Parent. Tell the user to make a USER token with "API Tokens: Edit".

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
