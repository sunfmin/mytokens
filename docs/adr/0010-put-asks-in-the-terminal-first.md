# `put` asks in the terminal first, then the popup, else fails with the command

`put` collects secret Fields from whichever input reaches a human in this run: the
**controlling terminal** when there is one, else the **desktop popup**, else nothing, and then
it stores nothing and prints the exact command to run in a terminal. This extends ADR-0002
and ADR-0009, where secret values always came from the popup.

## Context

The popup needs a desktop (WindowServer) session. Over SSH to a Mac with no one logged in
at the screen, or one only ever reached over SSH, there is none, so `put` could not store a
Secret at all.

## Decision

- **Terminal**: when `/dev/tty` opens, each Field is read with `readpassphrase(3)` and
  `RPP_REQUIRE_TTY`. Input does not echo, except Fields named in `--show`, which echo as the
  popup shows them. It reads the tty, not stdin, so stdin/stdout may be pipes and the value
  never touches shell history, the transcript, or `ps` (the ADR-0002 property). The Service
  and Description are printed before the first Field, as the popup shows them.
- **Popup**: with no terminal but a desktop session (the Security session has graphic
  access), as before. This is the agent case: Claude Code's shell has no controlling
  terminal, so an agent-run `put` on the desktop still pops the dialog.
- **Neither**: `put` exits non-zero, stores nothing (not even `--set` values), and prints
  the command to run in a terminal, quoted so it can be pasted as is.
- The choice is `SelectingSecretInput`, the live `SecretInput` behind the existing
  `Dependencies` seam. `SecretInput` returns `PromptResult` (`entered` / `cancelled` /
  `unavailable`). A later input path, such as a one-time web link, joins as another
  candidate there.

## Considered Options

- **Popup first, terminal as fallback.** On a desktop with a terminal, the popup would keep
  today's look. Rejected: a human who runs `put` in a terminal is already at an input;
  a dialog would pull them away from it, and the rule "terminal if present" is the same on
  every host.
- **Read the secret from stdin.** Rejected: it invites `echo $TOKEN | mytokens put`, which
  puts the value in history and in the transcript.

## Consequences

- Terminal input is one line per Field, limited by the tty's canonical line limit (1024 bytes
  on macOS). A longer value (e.g. a multi-line key) goes base64 into one line, or uses the popup.
- Cancelling at the terminal (Ctrl-C) ends the process before anything is stored.
