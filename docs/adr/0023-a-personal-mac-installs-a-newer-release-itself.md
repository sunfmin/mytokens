# A personal Mac installs a newer published Release itself

Each Background Sync run on a personal Mac first checks the newest published Release of
`sunfmin/mytokens` and installs it when it is newer than the installed app. Amends ADR-0016.

## Context

factorium's cut (mytokens#8) publishes a Release through GitHub Actions but installs nothing. A
personal Mac that never installs it stays on the old version, and so does everything that
depends on that Mac's version. Background Sync already runs on every personal Mac, so it is the
natural place to catch up.

## Decision

- **Where.** In `server sync` (ADR-0016), after the Mac is known to be unlocked and before the
  hosts and vaults are synced, so the rest of the run goes on with the new version
  (`deps.app()` is read after the install).
- **Check.** The newest published (non-draft, non-pre-release) Release of `sunfmin/mytokens`
  (GitHub's "latest release", tag `v<version>`). At most one check per hour: the time of the last
  check, success or failure, is kept in Background Sync's per-Mac status
  (key `release:sunfmin/mytokens`).
- **Install.** Only when the Release is newer than the installed app (`isOlder`), by the one way
  installs happen: the app's own `scripts/install.sh` (the notarized zip, then `selftest`), with
  `MYTOKENS_AGENT=0` because the launchd agent that runs this process must not be reloaded under
  it; its plist runs the `~/.local/bin` link and needs no change. Same or older: nothing.
- **Failure.** A failed check or install is logged by the run, kept in the status, and shown as a
  `this Mac` line in `server list`; the next hour retries. It never stops the sync of hosts and
  vaults. The run exits non-zero, like a failing host.
- **Personal Macs only.** `server sync` is refused on a Server, so a Server never checks.
  `server pause` pauses the check with the rest of Background Sync.

## Considered Options

- **A second launchd agent for upgrades.** Rejected: one agent, one lock, one status; the run
  already is "keep this Mac current".
- **Check every run (15 minutes).** Rejected: needless GitHub traffic; an hour is soon enough.

## Consequences

- `CONTEXT.md` **Background Sync** and the README name it.
- Tests use a fake release source and installer.
