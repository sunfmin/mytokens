# A labelled Field may hold a list of records

Amends ADR-0005 (the field schema) and ADR-0017 (`--field-from-stdin`). A labelled **Field** is
text, as before, or a **list**: an ordered JSON array whose elements are flat objects, each key a
non-empty string and each value a string, such as
`[{"host":"db1","user":"app","password":"…"},{"host":"db2","user":"app","password":"…"}]`.

## Context

Felix, 2026-11-18 (mytokens#1): 「要支持一列，存一个数组的东西……数组里面还有可以结构化数据」.
Some credentials come as a set of records of the same shape, such as one login per database
host or one token per runner. Until now they went in one Field as JSON text, which `get --json`
printed as a string inside a string, and `list` could not say how many records there were. Or
they went in one Field per record (`db1 password`, `db2 password`, …), which loses the shape.

## Decision

- **Entered from stdin only.** `put <service> --field-from-stdin "<Label>" --list` reads a JSON
  array of records from stdin, under ADR-0017's rules: stdin only, refused when it is a terminal
  or empty, one trailing newline stripped, upserted beside the Secret's other Fields. Stdin that is
  not a non-empty array of non-empty flat records with string values is refused, and the message
  names the expected shape. The check runs before anything is read from or written to the store.
  `--list` without `--field-from-stdin` is refused.
- **One-string paths refuse a list.** `--fields` (terminal, popup, one-time link), `--set` and a
  `--field-from-stdin` without `--list` each carry one string. Naming a Field that is a list with
  one of them is refused, and the message names `--field-from-stdin "<Label>" --list`. Writing
  `--list` to a text Field turns it into a list.
- **Recorded in the field schema.** The keychain comment (ADR-0005) gains
  `"lists": {"<Label>": <record count>}` beside `"fields"`, so the Field reads back as a list. The
  count is written from the value on every write, never on its own. It is there so that `list`
  can show the count without reading a value. The value object keeps each list as its canonical
  JSON text: compact, records in order, keys sorted within each record. A build from before lists
  therefore reads a list as a text Field holding that JSON, and does not fail.
- **Read.** `get --field "<Label>"` prints the canonical JSON. `get --json` puts the array itself,
  not a string, under `fields`. `list` shows the label as `Hosts (list, 2 records)` and never shows
  values.
- **Not in a Profile.** An environment variable holds one string. `put --kind profile` with
  `--list` is refused, and so is `--list` into an existing Profile. `env` refuses a Profile that
  holds a list Field anyway, for example one written by another build.
- **Sync carries it.** A wire Field gains `"list": true`. Push and adoption store it as a list on
  the other side, and a second `sync` changes nothing. A Server running an older build drops the
  mark and keeps the text.

## Considered Options

- **Store the array itself in the value object.** Rejected: an older build on another personal
  Mac (the iCloud Keychain carries the item there) would fail to decode the whole Secret. The
  text form degrades to a readable text Field.
- **Count the records in `list` by reading each value.** Rejected: `list` reads no values, and
  the count is cheap to keep beside the label it describes.
- **Nested values, or numbers and booleans in a record.** Rejected for now. Flat string records
  cover the case at hand, and every value stays a string as it is everywhere else in mytokens.
- **Entering a list in the popup or a one-time link.** Rejected: a list is made by a command or
  an agent assembling records, not typed by a human into one masked row.

## Consequences

- `SecretValue` carries `lists`, the labels of its list Fields. That is the one place the kind of
  a Field is recorded in memory, and `SecretRecord.lists` carries the counts derived from it.
- ADR-0017's rule for stdin applies to a list as well: an agent pipes in only a list that a
  command makes, never values a human typed or pasted into chat. A list whose values only a
  human knows has no entry path yet.
