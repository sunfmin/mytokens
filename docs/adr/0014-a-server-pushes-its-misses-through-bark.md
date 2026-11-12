# A Server says why it lacks a Secret, and pushes that through Bark

Status: narrows ADR-0004 for one case.

When a job on a **Server** asks (`get`, `env`) for a Secret the Server does not hold — a
**Miss** — the command still exits non-zero, but it says why and what to run, and the Helper
itself sends that as one Bark push, using the Server's own `bark` Secret.

## Context

A Server holds only `server`-level Secrets, Synced from a personal Mac (ADR-0010, ADR-0012).
A job there that needs one it lacks got `no secret for …`. The agent then asked for the value in
chat or tried `put` on the Server — the wrong home for it — and nobody watching learned which
Secret to raise. Felix decided (sunfmin/control#744, 2026-11-12) that a Miss names its own fix
and reaches him through Bark, his push service.

## Decision

- On a Server, a Miss prints: the Secret is not on this Server; a Server holds only
  `server`-level Secrets Synced from the personal Macs; the line to run on a personal Mac,
  `mytokens put <service> [--account <a>] --level server` (an existing Secret: only its level
  changes; a new one: it is entered there); and that the next Sync brings it, or `mytokens sync
  <this host>` now. The exit code stays 1. On a personal Mac a Miss is unchanged.
- With a `bark` Secret (account `default`) on the Server, the Helper POSTs the same content to
  Bark: a lone value is a device key (sent to `https://api.day.app/<key>`) or a whole push URL;
  labelled Fields may name `key`/`Device Key` and `server`, or `url`. Without one it only
  prints.
- At most one push per Secret per Server per hour, kept in
  `~/Library/Application Support/mytokens/miss-pushes.json` under a file lock, so jobs missing
  at once push once. The limit is a courtesy: a ledger it cannot read never stops a push, and a
  failed push never changes the exit code or hides the message.
- A Secret the Server holds, a missing Field of one it holds, and `put` are untouched.

## Narrows ADR-0004

ADR-0004 keeps service-specific code and network calls out of the Helper. A Miss push is the
one exception: it is the Helper telling its own user about itself, not acting on a Service for a
task, and only the Helper knows, at the moment of the Miss, that it happened and whether the hour
has passed. The push carries no Secret value — only names, the host and the line to run. The
Helper is not sandboxed, so it needs no new entitlement. Minting and every other Service-specific
behaviour stay runtime patterns in the skill.

## Considered Options

- **Leave the push to the agent, from the skill.** Rejected: every job's agent would need the
  rate limit and the Bark recipe, and a job that is a plain script, not an agent, would tell no one.
- **Push on every Miss.** Rejected: a job retrying in a loop would flood the phone.
