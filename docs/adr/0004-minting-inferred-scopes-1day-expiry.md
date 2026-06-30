# Minting: Claude infers scopes, Child tokens expire in 1 day, best-effort revoke

When Claude needs Cloudflare access, the Helper mints a Child token from the stored Parent.
Claude **infers the Child's policy** (permission groups + zone/account scope) per task; the
default **`expires_on` is 24 hours**, configurable in the Parent's metadata; cleanup is a
**best-effort `mytokens cloudflare revoke <id>`** with expiry as the guaranteed backstop.

## Context

The user prioritizes frictionless daily use over minimal blast radius. Cloudflare enforces
that a Child can never exceed the Parent, so the Parent's own permissions are a hard ceiling
regardless of what Claude infers.

## Why this still buys security

Even a broad, 24-hour Child is safer than using the Parent directly: the Parent holds the
**token-creation** permission (privilege escalation — it can mint more tokens), and an
inferred Child won't. So minting prevents escalation even when scope/time are loose.

## Consequences

- A Child may be broadly scoped and live a full day, and per ADR-0002 its value can surface
  in the transcript. Accepted under the trusted-machine threat model.
- The Helper exposes `mytokens cloudflare permissions` (Cloudflare's `permission_groups`
  catalog, fetched via the Parent) so Claude can resolve permission-group GUIDs when building
  a policy.
- Scope inference is unaudited by construction; the 24h expiry + best-effort revoke are the
  only cleanup mechanisms. Revisit if a tighter posture is ever wanted.
