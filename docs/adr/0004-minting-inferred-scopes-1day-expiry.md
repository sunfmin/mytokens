# Minting is a runtime pattern over a service-agnostic Helper, not a Helper feature

The Helper stays **service-agnostic**: it only stores and returns Secrets (generic
`add`/`get`/`list`/`rm` plus optional `--kind`/`--meta`). It contains **no Cloudflare code
and no network capability**. Minting a Cloudflare Child token is a **pattern Claude performs
at runtime** — documented in `SKILL.md` as a worked example — not a Helper command.

## Context

Cloudflare is just one example Service. An earlier draft of this ADR put
`cloudflare mint/permissions/revoke` commands inside the signed Helper, which special-cases
one service and bloats the signed binary with network + API logic.

## Decision

- The Helper does generic secret storage only.
- To mint, Claude: `mytokens get cloudflare` → calls Cloudflare's create-token API (via
  `curl`/`wrangler`) → uses the Child → best-effort revokes it.
- The **pattern** is preserved: Claude infers minimal scopes (bounded by the Parent's
  ceiling, which Cloudflare enforces), defaults the Child to a **24h** `expires_on`
  (configurable), and relies on expiry as the cleanup backstop.
- Adding another mintable Service later is "write a recipe in the skill," not "ship Helper code."

## Why this is better

- The signed app stays minimal → smaller attack surface, simpler signing/maintenance, no
  network entitlements.
- No special-casing: every Service is treated uniformly by the Helper.
- `get` already returns the raw value (ADR-0002), so Claude has everything it needs to mint,
  verify, and enrich at runtime.

## Consequences

- Verification/enrichment also moves to runtime: after `add`, Claude can `get` the token and
  call the Service's verify endpoint to confirm it and discover metadata (e.g. Cloudflare
  `account_id`). The value passes through Claude at that point — consistent with ADR-0002's
  trusted-machine model.
- Why minting still buys security: a minted Child lacks the Parent's token-creation
  permission, so even a broad 24h Child cannot escalate by minting more tokens.
