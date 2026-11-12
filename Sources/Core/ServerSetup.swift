import Foundation

// `server add <host>` and `server rm <host>`, on a personal Mac (ADR-0015): set up a Server in
// one command, and take one off the Server list. Every remote step goes over `Remote` (ssh),
// and Secret values cross only in Sync's SSH pipes, as `sync` alone does (ADR-0012).

/// This Mac's MyTokens release: the version a Server must reach, and the installer the
/// Server runs to get it — `scripts/install.sh`, shipped inside the app, fed over ssh's
/// stdin so the Server needs nothing first. Tests pass their own.
struct AppRelease {
    var version: String?
    var installScript: () -> Data?

    /// The running app's: found from the executable, through the `~/.local/bin` symlink.
    static var current: AppRelease {
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath()
        let app = exe?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundle = app.flatMap(Bundle.init(url:)) ?? Bundle.main
        return AppRelease(version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
                          installScript: { bundle.url(forResource: "install", withExtension: "sh").flatMap { try? Data(contentsOf: $0) } })
    }
}

/// The commands `server add` runs on the Server, besides Sync's.
let remoteVersionCommand = #"p="$HOME/Applications/MyTokens.app/Contents/Info.plist"; if [ -f "$p" ]; then /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$p"; else echo none; fi"#
/// The installer runs with `MYTOKENS_AGENT=0`: a Server never gets the Background Sync agent,
/// and its role is not set yet when it installs (ADR-0016).
let remoteInstallCommand = #"MYTOKENS_SELFTEST=0 MYTOKENS_AGENT=0 /bin/bash -s"#
let remoteSetRoleCommand = #"PATH="$HOME/.local/bin:$PATH" mytokens host server"#
let remoteSelftestCommand = #"PATH="$HOME/.local/bin:$PATH" mytokens selftest"#

/// Whether version `a` is older than `b`, comparing dot-separated numbers (`0.1.9` < `0.1.10`).
func isOlder(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
        let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
        if l != r { return l < r }
    }
    return false
}

private func validHost(_ host: String) -> Bool { !host.isEmpty && !host.hasPrefix("-") }

/// `server add <host>`: install or upgrade MyTokens there, set it `server`, pass selftest there,
/// Sync, then put it on the Server list. Each step must succeed before the next; a failure
/// names its step and leaves the host off the list (or as it was, when already on it).
/// Again on a listed host it does the same steps and changes nothing else: the repair command.
func serverAdd(_ host: String, store: SecretStore, list: ServerList, via remote: Remote,
               app: AppRelease, now: Date, state: BackgroundSyncState) -> CommandResult {
    guard validHost(host) else {
        return CommandResult(stdout: "", stderr: "server add needs a host name (got \"\(host)\")\n", exitCode: 64)
    }
    var lines: [String] = []
    func failed(_ step: String, _ why: String) -> CommandResult {
        CommandResult(stdout: lines.map { $0 + "\n" }.joined(),
                      stderr: "server add \(host) failed to \(step); it is not added to the server list:\n" + why,
                      exitCode: 1)
    }
    // 1. Install or upgrade; 2. the role, then selftest.
    do {
        lines.append(try installIfNeeded(on: host, via: remote, app: app).line)
        lines += try setRoleAndSelftest(on: host, via: remote)
    } catch let failure as StepFailure {
        return failed(failure.step, failure.why)
    } catch {
        return failed("install MyTokens", "\(error)\n")
    }

    // 3. The first Sync.
    let synced = sync(with: host, store: store, via: remote, now: now)
    lines += synced.stdout.split(separator: "\n").map(String.init)
    guard synced.exitCode == 0 else { return failed("sync", synced.stderr) }
    state.update(host) { $0.succeeded(at: now) }

    // 4. The Server list.
    do {
        let hosts = try list.read()
        if hosts.contains(host) {
            lines.append("\(host) is on the server list")
        } else {
            try list.write(hosts + [host])
            lines.append("added \(host) to the server list")
        }
    } catch {
        return failed("record it", "\(error)\n")
    }
    return CommandResult(stdout: lines.map { $0 + "\n" }.joined(), stderr: "", exitCode: 0)
}

/// `server rm <host>`: Sync the host to hold no Secrets at all — adopting what was entered
/// there first, and stopping on a conflict as Sync does — then forget it.
func serverRm(_ host: String, store: SecretStore, list: ServerList, via remote: Remote, now: Date,
              state: BackgroundSyncState) -> CommandResult {
    guard validHost(host) else {
        return CommandResult(stdout: "", stderr: "server rm needs a host name (got \"\(host)\")\n", exitCode: 64)
    }
    do {
        let hosts = try list.read()
        guard hosts.contains(host) else {
            return CommandResult(stdout: "", stderr: "\(host) is not on the server list\n", exitCode: 1)
        }
        let emptied = sync(with: host, store: store, via: remote, now: now, holding: .nothing)
        guard emptied.exitCode == 0 else {
            return CommandResult(stdout: emptied.stdout,
                                 stderr: emptied.stderr + "\(host) stays on the server list\n", exitCode: 1)
        }
        try list.write(hosts.filter { $0 != host })
        state.forget(host)
        return CommandResult(stdout: emptied.stdout + "removed \(host) from the server list\n", stderr: "", exitCode: 0)
    } catch {
        return CommandResult(stdout: "", stderr: "\(error)\n", exitCode: 1)
    }
}

/// `server list`: the hosts on the Server list, one per line, each with what this Mac's
/// Background Sync last did there: when it last synced, and the failed step, error and fixing
/// line while it fails (ADR-0016). Nothing secret.
func serverList(_ list: ServerList, state: BackgroundSyncState) -> CommandResult {
    do {
        let hosts = try list.read()
        let paused = state.isPaused() ? "background sync is paused on this Mac (mytokens server resume)\n" : ""
        if hosts.isEmpty { return CommandResult(stdout: "", stderr: "no servers on the server list\n" + paused, exitCode: 0) }
        let statuses = state.statuses()
        let rows = hosts.map { host -> String in
            let status = statuses[host]
            var row = "\(host)\t\(describeStatus(status))"
            if let status, status.isFailing, let step = status.failedStep {
                row += " — fix: " + fixLine(host: host, StepFailure(step: step, why: status.failedError ?? ""))
            }
            return row + "\n"
        }
        return CommandResult(stdout: rows.joined(), stderr: paused, exitCode: 0)
    } catch {
        return CommandResult(stdout: "", stderr: "\(error)\n", exitCode: 1)
    }
}

/// `server pause` / `server resume`: stop and restart this Mac's Background Sync. Kept per
/// Mac; resuming runs it at once.
func serverPause(_ paused: Bool, deps: Dependencies) -> CommandResult {
    do {
        try deps.syncState.setPaused(paused)
    } catch {
        return CommandResult(stdout: "", stderr: "\(error)\n", exitCode: 1)
    }
    if paused {
        return CommandResult(stdout: "background sync paused on this Mac; mytokens server resume restarts it\n", stderr: "", exitCode: 0)
    }
    triggerBackgroundSync(deps)
    return CommandResult(stdout: "background sync resumed on this Mac\n", stderr: "", exitCode: 0)
}

/// `server agent`: install or refresh this Mac's Background Sync agent (install.sh runs it on
/// every install and upgrade); on a Server, remove it — a Server never runs one.
func serverAgent(role: HostRole, deps: Dependencies) -> CommandResult {
    do {
        if role == .server {
            try deps.agent.remove()
            return CommandResult(stdout: "this Mac is a server: no background sync agent here\n", stderr: "", exitCode: 0)
        }
        try deps.agent.install()
        return CommandResult(stdout: "background sync: every \(LaunchdAgent.interval / 60) minutes and after a server-level change (launchd agent \(LaunchdAgent.label))\n",
                             stderr: "", exitCode: 0)
    } catch {
        return CommandResult(stdout: "", stderr: "background sync agent not loaded: \(error)\n", exitCode: 1)
    }
}
