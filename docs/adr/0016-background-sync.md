# Personal Macs Sync every listed Server in the background

Each personal Mac runs a launchd agent that Syncs every host on the **Server list** every 15
minutes and right after a command on that Mac changes a `server`-level Secret. Nobody has to
remember `sync`. ADR-0015 announced this as "the next change".

## Context

Felix, 2026-11-12 (sunfmin/control#743): 「我也经常忘了同步」— he often forgets to sync. A
Server then runs on with stale Secrets, or none, until someone notices a Miss (ADR-0014). The
Server list (ADR-0015) already names every Server, and Sync is idempotent (ADR-0012), so a
personal Mac can safely keep every Server current by itself.

## Decision

- **The agent.** `~/Library/LaunchAgents/com.sunfmin.mytokens.background-sync.plist`, in the
  user's GUI domain, runs `~/.local/bin/mytokens server sync` every 15 minutes
  (`StartInterval` 900, Felix's choice) and at load. A sleeping Mac does not run it; launchd runs
  it once on waking, which catches up. `scripts/install.sh` (every install and upgrade) and `make
  install` write and reload it through `mytokens server agent`. The plist runs the
  `~/.local/bin` link, so an app upgrade needs no change to it.
- **Personal Macs only.** On a Server, `server agent` removes the agent, and `host server` does
  too. `server add` runs the installer with `MYTOKENS_AGENT=0`, since a fresh Server has no role
  yet when it installs. `server sync`, `pause` and `resume` are refused on a Server, like
  `sync`. On a Server the agent installs nothing and runs nothing. What a Server gets comes only
  over SSH, from Sync and from the upgrade.
- **Right after a change.** A successful `put` or `rm` on a personal Mac kicks the agent
  (`launchctl kickstart`) when the Secret was or now is `server`-level. That covers creating,
  updating, raising to `server`, lowering to `personal` and removing. The command does not wait
  for the Syncs. A personal-level change kicks nothing.
- **One run.** For each listed host, on its own: read MyTokens' version there. If it is missing
  or older than this Mac's, upgrade it, set the role and run selftest, as `server add` steps 1–2
  do. Then Sync. A host that fails does not stop the others. Runs use ssh with
  `BatchMode=yes` and `ConnectTimeout=20`, so a host that cannot be reached, or that wants a
  prompt, fails fast instead of hanging the run.
- **One run at a time per Mac.** `server sync` holds a lock
  (`~/Library/Application Support/mytokens/background-sync.lock`). A run started while another
  is in progress waits for it. A kick while a run is in progress leaves a pending mark, and the
  run goes round once more before it exits. Two personal Macs may run at the same moment. Sync
  is idempotent, so the second run prints `no changes`.
- **Before the first unlock** this Mac's keychain is unreadable (ADR-0011). The run then does
  nothing and says it is waiting. The next interval or kick tries again.
- **Status, per Mac.** `~/Library/Application Support/mytokens/background-sync.json` keeps, for
  each listed host, the time of its last successful Sync. While its runs fail, it also keeps the
  failed step (`install MyTokens`, `set the role`, `pass selftest`, `sync`), the error Sync or
  the Server printed, and when the failures began. A successful `server add` or `sync <host>` of
  a listed host also counts as its last Sync. `server list` prints each host with this status,
  plus the line that fixes a failure where one is known (a locked Server after a reboot: "log in
  once at <host>"; unreachable; ssh wanting a prompt; a conflict; otherwise `server add <host>`).
  A host taken off the list is forgotten. Nothing here is secret: Sync never prints a value.
- **Bark after 24 hours.** A host failing for 24 hours straight gets a Bark push with this Mac's
  own `bark` Secret (`BarkTarget`, as ADR-0014): the host, how long, the failed step and error,
  and the fixing line. Another push follows each further 24 hours while it keeps failing. A push
  that does not get through is tried again at the next run. Without a `bark` Secret here, the
  failure shows only in `server list`.
- **Pause.** `server pause` stops this Mac's background runs (a file beside the status, so it is
  per Mac). `server resume` restarts them and kicks a run at once.
- **No value is logged.** The agent's log (`~/Library/Logs/mytokens/background-sync.log`) gets
  what `server sync` prints: host names, Secret names, steps and errors. Values cross only in
  Sync's SSH pipes (ADR-0012).

## Considered Options

- **Sync from the Server side (a Server pulls).** Rejected: a Server cannot read the iCloud
  Keychain, and the personal Mac is every Secret's home (ADR-0012).
- **Kick by running the Syncs inside `put`.** Rejected: `put` would wait on SSH to every
  Server. Kicking the agent returns at once and keeps one run at a time.
- **Keep the status in the iCloud Keychain beside the Server list.** Rejected: each personal Mac
  runs its own agent and has its own failures to report, and two Macs would overwrite each
  other's status.
- **Push through Bark on every failure.** Rejected: a Server that is merely rebooting would
  push every 15 minutes. Twenty-four hours of failure is worth a human's attention.

## Consequences

- `CONTEXT.md` gains **Background Sync**.
- `server list` prints `<host>\t<status>` instead of the bare host. It still lists only names
  and times, and nothing secret.
- A trigger can be lost in a narrow race: the run checks for a pending mark, a kick arrives
  before the process exits, and launchd ignores it as already running. That change waits for the
  next 15-minute run at most.
