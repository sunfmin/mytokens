# `server add` sets up a Server in one command; the personal Macs keep one Server list

`mytokens server add <host>`, on a personal Mac, sets up a Server end to end and records it in
the **Server list**, which every personal Mac shares. `server list` prints the list; `server rm
<host>` empties the Server and takes it off. Background Sync (the next change) keeps every
listed Server current. The personal Mac stays every Secret's home (ADR-0012), and a Server keeps
holding its copies, so it runs on while the personal Macs are off (ADR-0010).

## Context

Felix, 2026-11-12 (sunfmin/control#742): the Secrets live on his own Mac and a Server gets them
from it. He often forgets to Sync, and a new machine stays without MyTokens and without its
Secrets until someone remembers both steps. No step may depend on remembering. A Server is set
up by hand today in four commands run on the Server itself (install, `host server`, `selftest`)
plus a `sync` from a personal Mac. macstudio-jp, the first real use, runs four fleets and has no
MyTokens at all.

## Decision

- **`server add <host>`**, over `ssh <host>`, each step only after the one before succeeded:
  1. Reads the Server's installed MyTokens version (the app's `Info.plist`). When it is missing
     or older than this Mac's, it runs `scripts/install.sh` there — the very script, shipped
     inside the app and fed over ssh's stdin, so the Server needs nothing first. That script
     installs the same signed, notarized Release it installs everywhere. It runs with
     `MYTOKENS_SELFTEST=0`, since step 2 runs selftest once the role is set. A Server still
     older afterwards fails this step.
  2. Sets the role (`mytokens host server`) and runs `mytokens selftest` there.
  3. Runs a first Sync (Adopt, then push), exactly `sync <host>`.
  4. Adds `<host>` to the Server list.

  A failing step is named (`failed to install MyTokens`, `set the role`, `pass selftest`,
  `sync`, `record it`), relays the Server's error, and leaves the host off the list. On a host
  already listed it does the same steps and changes nothing else: it is also the repair command.
- **`server rm <host>`** Syncs the host to hold no Secrets at all: Adopt first; on a conflict it
  stops before removing anything and the host stays listed; otherwise the Server takes the
  adopted Secrets (marking them pushed, removing every other pushed one), then an empty set,
  which removes those too. Then the host leaves the list.
- **`server list`** prints the listed hosts, one per line.
- **The Server list is one synchronizable keychain item** in mytokens' access group (service
  `mytokens.server-list`, account `hosts`, readable after first unlock as ADR-0011), holding a
  JSON array of host names. iCloud Keychain sync gives every personal Mac the same list. It is
  not a Secret: its label lacks the Secrets' `mytokens: ` prefix, so `list`, Sync and
  `get --unpushed` never see it; `put` and `rm` refuse its service. It holds nothing secret.
- **Only a host named by `server add` is listed.** Nothing is discovered from the tailnet, which
  holds other people's machines (Felix's decision: an explicit list).
- All three are **refused on a Server**, like `sync`: a personal Mac is the home of every
  Secret.
- Values cross only in Sync's SSH pipes (ADR-0012). The install, role, selftest and version
  steps carry no Secret: none appears in output, argv, the environment or a file.
- **Background Sync** (the next change) Syncs every Server on the list from a personal Mac every
  15 minutes and right after a `server`-level change, so a listed Server stays current without
  anyone running `sync`.

## Considered Options

- **Discover Servers from the tailnet.** Rejected: the tailnet holds other people's machines,
  and a Server must be chosen, not found.
- **Keep the list in a local file on each personal Mac.** Rejected: Felix's two personal Macs
  would drift apart, and background Sync from either must reach every Server.
- **Store the list as a Secret.** Rejected: it would show in `list`, could be given a level and
  pushed, and is not a credential.
- **Have the Server fetch `install.sh` from GitHub.** Rejected: it would depend on the branch's
  current script rather than this Mac's release; sending the bundled script pins it.

## Consequences

- `CONTEXT.md` gains **Server list**; the README's "Set up a server" is `mytokens server add
  <host>`, run on your own Mac, with the by-hand steps kept as the fallback.
- The app bundle ships `install.sh` as a resource (`project.yml`).
- Two personal Macs writing the list at the same moment: the last write wins. Adding or
  removing again settles it.
