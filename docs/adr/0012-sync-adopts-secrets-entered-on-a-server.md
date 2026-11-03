# Push becomes sync, which also adopts the Secrets entered on a Server

`mytokens push <host>` is renamed **`mytokens sync <host>`**. Besides pushing, it **adopts**
each Secret entered on the Server: it brings it back to the personal Mac as a `server`-level
Secret, so from then on the personal Mac is its only home. This narrows ADR-0010, whose push
left a Secret entered on the Server itself untouched for good.

## Context

A Secret can be entered on a Server directly — `put` over SSH, or through a one-time link
(ADR-0010). It then lived only on that Server: lost with the machine, never on the user's own
Macs, and outside every `push`, which "never touches a Secret entered on the Server itself".
Felix's decisions (sunfmin/control#575, 2026-11-03):

- `sync` adopts such a Secret instead of leaving it there.
- This is **adoption, not two-way sync**: after `sync`, each Secret still has one home, the
  personal Mac. Changes, level moves and removals happen there and reach the Server on the
  next `sync`. There are no conflict rules between two homes, because there are never two.
- The command is called `sync`; `push` goes away with no alias (only Felix and agents use it).

## Decision

`mytokens sync <host>`, on a personal Mac, makes two runs of `ssh <host>`:

1. **Adopt.** `mytokens get --unpushed` on the Server writes every Secret it holds without the
   pushed mark — whole records, values included — to ssh's stdout. For each one:
   - With no Secret of the same service and account here, the personal Mac stores it as is
     (Fields, kind, meta, Description) at `server` level, its Description gaining
     `adopted from <host> on <yyyy-MM-dd>`. The push below marks it pushed on the Server: from
     then on it is a pushed Secret like any other.
   - With a Secret of the same service and account here, at any level, **neither side
     changes**; `sync` reports the conflict by name and leaves it for the human. A Server must
     never be able to overwrite a Secret on the user's own Macs: through the iCloud Keychain
     sync, that would reach every one of them.
   - One exception completes an adoption cut short (stored here, but the push never reached the
     Server): a `server`-level Secret here with the very same Fields, kind and meta is taken
     as adopted. The personal Mac does not change; the Server takes its record.
2. **Push**, as ADR-0010's push: `mytokens put --stdin` on the Server reads every
   `server`-level Secret here, adopted ones included and named as adopted, and the Server
   converges to it. Pushed Secrets that are gone, or no longer `server`-level, are removed from
   the Server; an unadopted conflict is left alone.

- Values cross only in the SSH pipes, both ways: never argv, the environment, a file or
  printed output. `get --unpushed` and `put --stdin` are both refused on a personal Mac.
- The output names what was `adopted`, `added`, `updated`, `removed` and in `conflict`, or
  `no changes` after both runs succeed. A conflict makes the exit status non-zero after
  everything else is done. A failed SSH run also exits non-zero, names the Adopt or push step
  and relays the Server's error; it never prints Secret values or reports `no changes`.
- A second `sync` with nothing changed on either side changes nothing.
- `mytokens push` prints a hint that names `sync`, and exits 64.

## Narrows ADR-0010

ADR-0010's "a Secret entered on the Server itself is never touched" now holds only for a
conflict. Every other Secret entered on a Server is adopted by the next `sync`. The rest of
ADR-0010 stands: a Server holds exactly the personal Mac's `server`-level Secrets once the
sync is done.

## Considered Options

- **Two-way sync**, each side's changes reaching the other. Rejected: two homes for one Secret
  need conflict rules, and a Server — a machine the user does not sit at — could then change
  Secrets on every personal Mac.
- **Adoption that overwrites the personal Mac's same-name Secret.** Rejected for the same
  reason: a Server must never write over a Secret on the user's own Macs.
- **Keep `push` as an alias.** Rejected: only Felix and agents use it, and one name per verb
  keeps the skill and README unambiguous.

## Consequences

- `CONTEXT.md`: **Push** becomes **Sync**; **Adopt** is new. The iCloud Keychain's own
  syncing between personal Macs is always named in full, "iCloud Keychain sync".
- A Server whose mytokens predates `get --unpushed` fails the first step: `sync` reports that
  and changes nothing there. Update it first.
