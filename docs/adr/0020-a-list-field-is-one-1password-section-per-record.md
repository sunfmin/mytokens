# A list Field goes to the 1Password vault as one section per record

Amends ADR-0022 (1Password vault) for the list Field of ADR-0019 (a Field may hold a list of records).

## Context

mytokens#4. A 1Password item holds fields, optionally grouped into sections; it has no array
or list field type (`op item create --help` and the item JSON template offer only the field
types, and a field's `section` is the one grouping). A list Field would otherwise reach the vault
as one JSON string, which a server could not address by record.

## Decision

- A list Field is written as **one section per record**: section label `<Label> [<i>]`
  (1-based, in record order), one **concealed** field per record key, in key order (sorted, as
  the canonical form is). In the template: top-level `"sections": [{id, label}]` and each field
  carries `"section": {id, label}`. A text Field is unchanged.
- Record count changes add or remove sections, because the template is written whole. The digest
  tag covers the list (marked as a list), so an unchanged list makes no `op` write.
- A server reads one value with `op read "op://<vault>/<title>/<Label> [1]/<key>"`, or rebuilds
  the array with `op item get "<title>" --vault <vault> --format json`: take the
  fields whose `section.label` is `<Label> [<i>]`, group by section in `<i>` order, and make an
  object `{label: value}` of each group.

## Considered Options

- **One JSON-text field holding the array.** Rejected: no per-record addressing in `op read`.
- **One field per record and key, flat (`Hosts 1 host`).** Rejected: sections are 1Password's own
  grouping, and the section label keeps the record index apart from the key.

## Consequences

- Not verified against a real 1Password: this was built from the CLI help and the template shape
  with a fake `op` in tests (the template it receives is asserted). That `op item edit --template`
  replaces the whole field set (so that removed records go) and that `op read` resolves a section
  label containing `[ ]` are assumed; if either fails, read with `op item get ... --format json`.
