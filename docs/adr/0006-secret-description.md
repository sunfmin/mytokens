# A Secret carries an agent-authored Description, first-class and distinct from Meta

Every Secret may carry a **Description**: a short, human-readable note of what it is *for*,
set at `add` time via `--description` and shown by `list` and in the input popup. It is a
first-class field — its own flag and its own slot in the stored item — **not** a key inside
`--meta`.

## Context

When an agent runs `mytokens list`, it sees `service/account`, `kind`, and (now) field
labels — but nothing about *why* a Secret exists or what task it serves. A later run (or a
different agent) can't tell `aws/default` for CI deploys from `aws/default` for a one-off
script. The agent that stored the Secret knew its purpose; that knowledge should outlive the
single run that created it.

`--meta` already stores arbitrary JSON, so the cheap option is "just put a `description` key
in `--meta`." But Meta and Description answer different questions and have different readers.

## Considered Options

- **A `description` key inside `--meta`** (convention, zero code). Rejected: it buries the one
  thing we most want an agent to see inside a JSON blob, mixes prose-for-a-reader with
  structured-data-for-a-program, and nothing makes the agent reliably set it.
- **Require `--description` on every `add`.** Rejected: it breaks the bare human path
  (`mytokens add cloudflare`, just type the value) and existing entries, and it turns the
  Helper into something more than "store a value."
- **A separate `mytokens describe` command** to edit the note without re-entering the secret.
  Deferred (not rejected): editing wasn't needed yet, and a description is usually right when
  first written. Adding it later is cheap if re-`add`-to-edit proves annoying.

## Decision

- `add` takes an optional `--description "<text>"`, stored in the keychain comment beside
  `kind`/`meta`/`fields`. It is **optional in the Helper** (back-compat, human use) but the
  skill **mandates** the agent always set one (behavior lives in SKILL.md, per ADR-0004).
- `list` shows the Description prominently per row; the popup shows it to the human as the
  reason the dialog appeared (and, when present, in place of the generic instruction line).
- Description is **per-Secret** — one purpose for the whole credential, independent of how
  many Fields it has. `get` is unchanged (it returns the value, never the Description).

## Consequences

- Glossary gains **Description** and **Meta** as distinct terms (CONTEXT.md): Description is
  prose intent for a reader; Meta is structured data for a program.
- The Helper stays permissive; the convention is enforced where agent behavior is specified
  (SKILL.md), not in the signed binary — consistent with the minimal-Helper line of ADR-0004.
- Editing a Description still means re-`add` for now (which re-prompts for the value). If that
  friction bites, a metadata-only `describe` command is the documented next step.
