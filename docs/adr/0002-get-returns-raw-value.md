# `mytokens get` returns the raw secret value to stdout

The primary way Claude consumes a Secret is `mytokens get <service>`, which prints the
raw value to **stdout**. We deliberately do **not** make an `exec`-injection wrapper the
blessed path.

## Context

Claude composes arbitrary shell/API calls, so it needs the raw value in hand. The user's
threat model treats this machine — a single-user Mac with FileVault on — as trusted, so a
secret appearing in plaintext in the transcript, shell history, or `ps` is an acceptable
cost for that flexibility.

## Considered Options

- **`exec` wrapper** (`mytokens exec <svc> -- <cmd>`) that injects the secret into a child
  process's env and never returns it — structurally leak-proof. Declined: too constraining
  for arbitrary API composition, and unnecessary given the trusted-local-machine threat model.

## Consequences

- The secret can appear in plaintext on local disk (transcript logs, shell history) and in
  `ps`. Accepted on this machine; would need revisiting on a shared/untrusted host.
- Mitigations are conventions, not guarantees: `get` writes only to stdout and the Helper
  never logs the value; the skill instructs Claude to consume it via `$(…)` and never `echo`
  it or run under `set -x`.
- If the threat model changes, an `exec` path can be added later alongside `get`.
