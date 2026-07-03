# CLI arg handling stays minimal accessors, not a command-grammar DSL

The `mytokens` CLI parses `argv` with a small generic tokenizer (`parseArgs` →
`ParsedArgs { positionals, flags }`) and each command reads what it needs through
a handful of **semantic accessors** on `ParsedArgs` (`service`, `account`,
`flag(_:)`, `present(_:)`). We deliberately do **not** introduce a declarative
command-grammar / arg-spec layer, and `usage()` stays a hand-written string.

## Context

An architecture review flagged repeated extraction across `add`/`get`/`rm`:
`positionals.first`, `flags["account"] ?? "default"`, the
`.flatMap { $0.isEmpty ? nil : $0 }` non-empty-flag dance, and a `usage()` string
maintained separately from what the code actually accepts. The tempting fix is to
"declare the command grammar once" — a spec listing each command's flags, with the
parse and the usage line generated from it.

## Decision

- Extend `ParsedArgs` with four accessors and use them at the call sites:
  - `service` (first positional), `account` (**defaults to `"default"`**),
    `flag(_:)` (value, treating present-but-empty as absent), `present(_:)` (bool).
- The **`account` default lives in exactly one place.** `add`, `get`, and `rm` must
  agree on it — if they drifted, a Secret would be stored under one account and
  silently fail to `get`/`rm`. That single-source-of-truth is the accessor set's
  main justification, not tidiness.
- Leave `--kind`, `--meta`, `--fields`, `--show` reading `flags[…]` directly: their
  empty-value handling differs (kind has its own default; meta wants mere presence;
  fields/show flow through `splitCSV`), so folding them into `flag(_:)` would change
  behavior for no gain.
- Keep `usage()` hand-written.

## Why not the DSL

- At **four commands**, arg parsing isn't complex enough to hide behind a small
  interface — a grammar spec would be a **shallow module** (its declaration nearly
  as large as the parsing it replaces), trading real duplication for ceremony.
- Generated `usage()` is the specific over-engineering the review warned against:
  the payoff (usage can't drift) is small when the whole surface is four commands
  and one screen of help text.

## When to revisit

If the command count grows past a handful, or flags start being shared across many
commands with per-command validation, a declared grammar (parse + usage from one
spec) begins to pay for itself. Until then this ADR exists so future architecture
reviews don't re-suggest "declare the command grammar once" — it was considered and
scoped down on purpose.

## Consequences

- New commands copy the `guard let service = args.service else { return usage() }`
  line and add a `usage()` entry by hand — accepted at this scale.
- The accessors carry no new domain vocabulary; `CONTEXT.md` is unchanged.
