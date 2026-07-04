# Profiles: named env-var bundles emitted as shell `export` lines via `mytokens env`

> **Status:** the entry-method decisions here — *"split entry declined"* and *"uniform
> popup"* — are **superseded by ADR-0009**: non-secret values now come from the CLI via
> `--set`, and the write verb is `put`, not `add`. The Profile concept and `env` rendering
> below still stand.

mytokens gains a **Profile** — a named bundle of environment variables (a provider's
endpoint, model, and token) stored as a `--kind profile` multi-field Secret and emitted by a
new `mytokens env <service>` command as POSIX `export` lines for `eval`, so a tool launched
in that shell (e.g. Claude Code pointed at a different provider) inherits them. We keep this
on the **stdout** side of ADR-0002 (no `exec` launcher) and reuse ADR-0005's multi-field
storage rather than adding a new store shape.

## Context

Users want to launch another CLI — Claude Code is the motivating case — against a different
API provider by loading a set of env vars (`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`,
`ANTHROPIC_MODEL`). A single credential (ADR-0002) doesn't model this: the bundle is *mostly
non-secret config*, the parts are used together, and it is consumed by being injected into a
process environment rather than spliced into one API call.

## Decision

- New concept **Profile** (CONTEXT.md): a named env-var bundle, *not* a credential. Stored
  physically as an ADR-0005 multi-field Secret whose Field labels are the env-var names,
  marked `--kind profile`.
- Created with the existing `add --fields` popup, all values (config + secret) entered in the
  one secure popup:
  ```sh
  mytokens add glm --kind profile --description "Claude Code → GLM" \
    --fields "ANTHROPIC_BASE_URL","ANTHROPIC_AUTH_TOKEN","ANTHROPIC_MODEL" \
    --show "ANTHROPIC_BASE_URL","ANTHROPIC_MODEL"
  ```
  `--show` reveals the non-secret config for paste-verification (reused, not inverted).
- `--kind profile` **requires** `--fields`; `--kind parent` still **forbids** them.
- Labels must be valid shell identifiers (`[A-Za-z_][A-Za-z0-9_]*`), validated at `add` time.
- New verb `mytokens env <service> [--account L]` prints one `export NAME='VALUE'` line per
  field, in stored order, each value single-quote-escaped (`'` → `'\''`) so `eval` is
  injection-safe. It **errors on a non-Profile Secret**. POSIX/sh/bash/zsh only; fish
  deferred behind a future `--fish`/`--format` flag.
- Consumed as `eval "$(mytokens env glm)" && claude`.
- Named by **provider** (`glm`), not by tool — the Profile is tool-agnostic; the tool is
  chosen at runtime in the seeded shell.

## Considered Options

- **`exec` launcher** (`mytokens exec glm -- claude`, inject into a child's env, never touch
  stdout) — ADR-0002's own "add `exec` later" escape hatch. Declined *for now*: `env` →
  `eval` stays inside ADR-0002's stdout model, is tool-agnostic (seeds the shell for any
  subsequent command, not just one), and avoids handing the tty to a child TUI. `exec` can be
  added later alongside `env` if the need appears.
- **By-reference Profiles** (a Profile points at a separately-stored Secret for the token).
  Declined by the Rule of Three: the motivating token feeds only this one Profile, so there
  is nothing to de-duplicate yet; inline keeps zero new storage machinery.
- **Split entry** (non-secret config as `--set K=V` on the CLI, secret via popup). Declined:
  we keep one uniform entry path (ADR-0005) over a two-source model, accepting that config is
  typed into the secure popup.
- **Separate `profile` command family** (`mytokens profile add/env/rm`). Declined per
  ADR-0007: it roughly doubles the surface; overloading `--kind` plus one new verb is the
  smaller change.

## Consequences

- The `--kind` axis now mixes a credential *role* (`static`/`parent`) with a non-credential
  *nature* (`profile`) — a slight category stretch, accepted to keep the surface tiny.
- `eval "$(mytokens env glm)"` exports the token into the interactive shell for the rest of
  the session (inherited by every child, visible in `ps -E`), consistent with ADR-0002's
  trusted-machine model. Scope it with a subshell — `(eval "$(mytokens env glm)"; claude)` —
  when the token should live only for that one launch.
- Bare `get` on a Profile behaves like any multi-field Secret (errors, lists labels);
  `env` is the Profile-native reader. `list` shows `kind=profile` and the field labels (the
  env-var names), never values.
- fish users have no output format until a `--fish`/`--format` flag is added.
