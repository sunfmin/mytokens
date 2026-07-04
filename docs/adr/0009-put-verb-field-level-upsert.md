# One `put` verb: field-level upsert replaces the whole-item `add`

The single write verb is **`put`** (renamed from `add`). `put` **upserts the named fields**
into a Secret and keeps the rest — non-secret values come from the CLI via repeatable
`--set NAME=VALUE`, secret values via the masked popup (`--fields`). There is **no whole-item
replace**: to rebuild a Secret from scratch, `rm` then `put`. This supersedes the atomic
whole-replace of ADR-0005 and the "uniform popup / split-entry rejected" of ADR-0008.

## Context

Importing a real Profile — 12 LongCat env vars, only one of them secret — exposed the friction
the uniform-popup rule (ADR-0008) created: eleven **non-secret** values would have to be typed
into a masked popup. And ADR-0005's *"re-add overwrites the whole Secret; Fields are not
independently updatable"* meant changing one value (say the model) forced re-entering every
field, including re-typing the token in the popup. Both rules predate a many-field,
mostly-non-secret Profile; that case is the forcing function to revisit them.

## Decision

- **Rename `add` → `put`.** No `add` alias (early, single-user tool). REST-ish pairing:
  `put` writes, `get` reads, `rm` deletes.
- **`put` upserts, never whole-replaces.** It reads the current item, updates/inserts the named
  fields, keeps the rest, and writes the whole item back through the store seam (`get` +
  `upsert`; no seam change). Creating = upserting into nothing.
- **Non-secret values on the CLI:** `--set "NAME=VALUE"`, repeatable, split on the **first**
  `=` (values may contain `=`, commas, spaces, `[]`). They never touch the popup.
- **Secret values in the popup:** `--fields "A,B"` (masked unless `--show`), as before.
- **Uniform across kinds.** `put` merges for `static`, `parent` (single-value), and `profile`
  alike — no kind-dependent replace-vs-merge split.
- **Any multi-field Secret's Fields are independently updatable**, composite credentials
  included: `put aws --fields "Secret Access Key"` rotates one and leaves the ID. Atomic
  multi-field rotation stays one command that names several fields:
  `put aws --fields "Access Key ID,Secret Access Key"` → one popup, one upsert.
- **Whole-replace = `rm` then `put`.** No `--replace` flag (YAGNI); add one later if atomic
  whole-replace is ever needed.
- Bare single-value Secrets (ADR-0002) unchanged: `put <svc>` with no `--set`/`--fields` pops
  one field and stores the lone value. A `put` cannot switch a Secret between the bare and
  labelled shapes, nor change its kind, on a merge (rm first).

## Supersedes

- **ADR-0005** — *"re-add overwrites the whole Secret"* and *"Fields are not independently
  updatable"*: both reversed. Its anti-orphan intent still holds — `put` reads-modifies-writes
  **one** atomic keychain item, so no half-credential is orphaned; and atomic key+secret
  rotation is preserved by naming both fields in one `put`. The multi-field storage model
  (JSON object + ordered label schema) is unchanged.
- **ADR-0008** — *"split entry (`--set`) declined"* and *"uniform popup"*: non-secret values now
  come from the CLI (`--set`); only secret fields use the popup. The Profile concept and `env`
  rendering are unchanged.

## Considered Options

- **Keep `add` (replace-whole) + add a `set` verb (patch one field).** Two verbs, uniform
  `add`. Rejected: one write verb was wanted; `put`-always-merges collapses create, bulk, and
  patch into one operation with no kind-dependent behavior.
- **A `--replace` flag for whole-replace.** Rejected for now (YAGNI); `rm` + `put` covers the
  occasional full rebuild and dropping stale fields.
- **Allow the secret on the CLI (`--set` for the token too).** Rejected as the default: the
  popup exists to keep the secret out of shell history / transcript / `ps` (ADR-0002).
  Non-secret config on the CLI is fine; the one secret stays in the popup.

## Consequences

- Every `put` is a read-modify-write over the store — harmless on a single-user machine (no
  concurrency).
- `put` reads via `get` + `list` (to recover the value and the kind/meta/description), so a
  merge preserves untouched fields and metadata.
- The parser gains repeatable-`--set` handling — a small, targeted extension, not the
  command-grammar DSL ADR-0007 warned against.
- To drop a stale field, or change a Secret's kind or shape, `rm` then `put`.
