# A Secret may hold multiple named Fields, stored as one item, addressed by label

> **Status:** the atomicity rules here — *"re-add overwrites the whole Secret"* and *"Fields
> are not independently updatable"* — are **superseded by ADR-0009** (field-level `put`). The
> multi-field storage model (one item, JSON object, ordered label schema) below still stands.

A **Secret** is one credential = one keychain item, holding **one or more named Fields**
(e.g. AWS *Access Key ID* + *Secret Access Key*). A multi-field Secret is collected in a
single popup, written atomically, and rotated/removed as a unit. Each Field is addressed by
its **label** (the label is the key). The single-Field case is unchanged and stays the
common path.

## Context

The Helper modelled a Secret as exactly one value: `(service, account) → value`, with `get`
returning that raw value (ADR-0002). But Claude sometimes needs to store a credential that
is intrinsically *several* values used together — AWS key + secret, a DB username + password.
These parts are created and rotated together and are useless apart, so prompting for them in
two separate popups (and storing two independent items that can drift or half-delete) models
them wrongly.

The value Claude knows at `add` time — and only Claude knows it, since it knows the target
Service — is the set of **field labels** to ask for. Hence labels are passed in at launch.

## Considered Options

- **Multiple Secrets, one per field** (new `field` key dimension, or reuse `--account`).
  The popup would be a batch-add over independent items. Rejected: `rm`/rotate can leave half
  a credential behind (an orphan), and reusing `--account` collides with its existing meaning
  (personal vs work). A composite credential is *one* thing; storing it as several lets illegal
  half-states exist.
- **Separate machine key + display label per field** (`--fields keyid="Access Key ID" …`).
  Decouples rename from address. Rejected as needless surface: Claude is both the writer and
  the reader, the label is a fine stable key, and a single string is one source of truth.
- **Bare `get` on a multi-field Secret dumps JSON (or KEY=VALUE).** Rejected as the default:
  it returns every field at once (more exposure than needed) and KEY=VALUE breaks on values
  with newlines/`=`. Kept as an *explicit* `--json` opt-in.

## Decision

- A Secret has **≥1 Fields**, each `{ label, masked }`. `add --fields "A","B"` pops one
  window with a labelled, all-required row per field (Store disabled until every field is
  filled); Cancel writes nothing. `--show "A"` renders named fields plain for paste
  verification; all others are masked. No `--fields` → today's single unlabelled value.
- **Storage**: a 1-field Secret stores its raw value in `kSecValueData` (back-compat,
  ADR-0002 intact). A >1-field Secret stores a JSON object `{label: value}` there, and records
  the ordered field-label schema in the keychain comment beside `kind`/`meta`.
- **Retrieval**: `get <svc> --field "<label>"` returns one field's raw value. Bare `get <svc>`
  returns the raw value when the Secret has one field and **errors** (listing the field labels)
  when it has more. `get <svc> --json` returns the whole field object.
- `list` shows field labels (never values). `rm` removes the whole credential. `--kind parent`
  is single-value by nature and is **rejected** together with `--fields`.

## Consequences

- The glossary term **Secret** is redefined (one credential, ≥1 named **Fields**) and a new
  term **Field** is added (CONTEXT.md).
- Fields are **not** independently updatable: re-`add` overwrites the whole Secret, which is
  exactly how an atomic key+secret rotation works.
- A label is the field's identity, so renaming a label is effectively a new field — Claude
  must use the same labels at `add` and `get` time. Labels are comma-separated in `--fields`,
  so a label containing a comma is unsupported (acceptable: real labels don't).
- A degenerate 1-field `--fields` Secret stores JSON but bare `get` still returns its lone
  value, so the "1 field ⇒ bare get works" rule holds regardless of how it was added.
