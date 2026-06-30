---
name: mytokens
description: >-
  Store and retrieve API tokens, keys, and secrets from the macOS Keychain, and
  auto-supply them when authenticating to an external service. Consult this BEFORE
  asking the user for any credential, or assuming a token/key is unavailable — for
  Cloudflare, GitHub, OpenAI, databases, and the like. Also mints short-lived,
  least-privilege Cloudflare child tokens from a stored parent token.
---

# mytokens

`mytokens` is a signed macOS Helper that keeps machine-usable **Secrets** in the iCloud
Keychain and hands them to you on demand. It is **service-agnostic**: it only stores and
returns values. Anything service-specific (e.g. Cloudflare token minting) is something
**you** do at runtime with the returned value — see the Cloudflare example below.

## When to use this (auto-invocation)

Before you ask the user for a credential, or conclude that a token/key isn't available, **check `mytokens` first**:

```sh
mytokens list                 # what's stored (services/accounts/kind; never values)
mytokens get <service>        # the raw value on stdout; non-zero exit if absent
```

If the Service has a Secret, use it. If `get` exits non-zero, the Secret isn't stored yet — offer to add it (this pops a secure popup; the value never passes through you):

```sh
mytokens add <service> [--account <label>] [--kind static|parent] [--meta '<json>']
# A credential with several parts (key + secret, user + password) → one popup:
mytokens add aws --fields "Access Key ID","Secret Access Key" --show "Access Key ID"
```

## Consent contract

- **Reading/using a stored Secret is silent.** The user storing it is standing authorization to use it — don't ask.
- **Announce, but don't gate, outward-facing writes.** Before minting or revoking a token (a write to the service's account), say what you're about to do (e.g. "minting a 24h DNS-edit Cloudflare child token"), then proceed without waiting for approval.
- **When a Secret is missing, pop the dialog** via `mytokens add <service>` rather than aborting the task.

## Consumption hygiene

The value is plaintext once `get` returns it (acceptable on this trusted machine — see ADR-0002), so don't make it worse:

- Consume inline: `curl -H "Authorization: Bearer $(mytokens get openai)" …` — don't assign it to a variable you later `echo`.
- Never `echo`/`print` a Secret, and never run the surrounding commands under `set -x`.

## Commands

| Command | Purpose |
|---|---|
| `mytokens add <service> [--account L] [--kind static\|parent] [--meta JSON]` | Popup → store. Collects only the value. |
| `mytokens add <service> --fields "<A>","<B>" [--show "<A>"]` | One popup, one row per field; masked unless `--show`. All required. |
| `mytokens get <service> [--account L]` | Raw value to stdout; non-zero exit if absent. |
| `mytokens get <service> --field "<A>"` / `--json` | One field's raw value / the whole field object as JSON. |
| `mytokens list` | Stored services/accounts/kind/fields/meta; never values. |
| `mytokens rm <service> [--account L]` | Delete the whole Secret. Re-`add` overwrites (rotation). |
| `mytokens selftest` | Real-keychain round-trip sanity check. |

`--account` lets one Service hold several Secrets (`cloudflare/personal` vs `cloudflare/work`).

### Multi-field credentials (ADR-0005)

Some credentials are several values used together — AWS *Access Key ID* + *Secret Access
Key*, a DB *Username* + *Password*. You know the parts (you know the Service), so pass the
field **labels** at `add` time; they're collected in **one** popup and stored as **one**
Secret that rotates and deletes as a unit.

- **Add**: `mytokens add aws --fields "Access Key ID","Secret Access Key" --show "Access Key ID"`.
  Labels are comma-separated; every field is required; `--show` reveals non-secret fields
  (identifiers) so the user can verify a paste — everything else is masked. `--kind parent`
  is single-value and can't be combined with `--fields`.
- **Get one field**: `mytokens get aws --field "Secret Access Key"` → that field's raw value
  (the label is the key — quote the spaces). Consume inline, e.g.
  `AWS_SECRET_ACCESS_KEY=$(mytokens get aws --field "Secret Access Key")`.
- **Bare `get`** returns the raw value for a single-field Secret, but **errors** for a
  multi-field one and lists the field labels — use `--field`, or `--json` to dump the whole
  `{label: value}` object.
- **`list`** shows the field labels (never values).

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
