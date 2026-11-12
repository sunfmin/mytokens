# `put --field-from-stdin` takes one secret Field a command pipes in

`put <service> --field-from-stdin "<Label>"` reads all of stdin as that one secret Field's value
and upserts it with no popup and no terminal prompt. It is the third entry path for a secret
Field, next to the terminal and the popup (or one-time link) of `--fields` (ADR-0009). Like
them, it keeps the value out of shell history, the transcript and `ps`.

## Context

Felix, 2026-11-12 (sunfmin/control#773): 「My token 没有直接从其他地方复制密码并作为输入的功能吗？」
Some Secrets are known to no human: a command makes them on the spot, such as a `.p12`
exported with `security export` or a password from `openssl rand`. `put` took a secret Field
only from the terminal (`/dev/tty`, one line, at most 1024 bytes), the popup or the one-time
link. So an agent copied the value to the clipboard and asked the human to paste it into a
popup. Storing the Developer ID `.p12` (4380 base64 characters) and its password that way
failed: two popups, both cancelled, nothing stored. `--set` would take the value, but it is for
non-secret Fields and puts the value in argv, which ADR-0009 rejects for a secret.

## Decision

- **The flag.** `--field-from-stdin "<Label>"` names one labelled Field. All of stdin is its
  value: there is no line limit. One trailing `\n` byte is stripped and nothing else is
  changed. The value must be UTF-8 text, so binary data goes in base64. Several stdin Fields
  take several `put` calls.
- **An upsert like `--fields`.** The Field is merged into the Secret, and its other Fields are
  kept (ADR-0009). It combines with `--set`, `--fields`, `--description`, `--level`, `--meta`
  and `--kind profile` the way `--fields` does, under the same checks: a label named twice is
  refused, a Profile's label must be an environment-variable name, a single-value Secret or a
  Parent token cannot take a labelled Field.
- **Refused for a human.** With stdin a terminal, `put` refuses and names `--fields`, so a
  human is not left typing into a prompt that shows nothing. An empty stdin (or a lone `\n`) is
  refused the same way. Both are checked before anything is read from the store or prompted.
- **The value stays out of sight.** It travels only in the pipe into the Helper and the
  keychain. `put` prints what it always prints (`stored <service>/<account>`) and puts the
  value in no output, argv, environment variable or file.
- **Both roles.** It works on a personal Mac and on a Server alike, under `put`'s level rules
  there (ADR-0010): on a Server the Secret is `server`-level and `--level personal` is refused.
- **Who may use it.** An agent uses it only for a value a command makes and pipes straight into
  `put`. It is never a way to relay a value a human typed or pasted into chat. A value a human
  knows still goes through `--fields`: the terminal, popup or one-time link.

## Considered Options

- **`--set` for secret values.** Rejected: argv shows up in `ps` and shell history (ADR-0009).
- **A whole Secret as JSON on stdin**, like the Server's `put --stdin` (ADR-0012). Rejected:
  that is Sync's own pipe, refused on a personal Mac, and it whole-replaces a Secret. One Field
  per call keeps `put`'s upsert and its checks.
- **Reading stdin when it is a terminal.** Rejected: the human would type into an unmasked or
  silent prompt that `--fields` already does better.

## Consequences

- `Dependencies` gains `stdinIsTerminal`, so tests drive the terminal refusal without a tty.
- The skill tells an agent when the flag is allowed. The rule is in the skill and not in code:
  the Helper cannot tell a generated value from a pasted one.
