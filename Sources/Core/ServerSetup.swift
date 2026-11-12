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
let remoteInstallCommand = #"MYTOKENS_SELFTEST=0 /bin/bash -s"#
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
               app: AppRelease, now: Date) -> CommandResult {
    guard validHost(host) else {
        return CommandResult(stdout: "", stderr: "server add needs a host name (got \"\(host)\")\n", exitCode: 64)
    }
    var lines: [String] = []
    func failed(_ step: String, _ why: String) -> CommandResult {
        CommandResult(stdout: lines.map { $0 + "\n" }.joined(),
                      stderr: "server add \(host) failed to \(step); it is not added to the server list:\n" + why,
                      exitCode: 1)
    }
    func run(_ command: String, stdin: Data = Data()) throws -> CommandResult {
        try remote.run(host: host, command: command, stdin: stdin)
    }
    func versionThere() throws -> String? {
        let r = try run(remoteVersionCommand)
        guard r.exitCode == 0 else { throw CommandResult(stdout: "", stderr: r.stderr, exitCode: r.exitCode) }
        let v = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty || v == "none" ? nil : v
    }
    func needsInstall(_ there: String?) -> Bool {
        guard let there else { return true }
        return app.version.map { isOlder(there, than: $0) } ?? false
    }

    // 1. Install or upgrade.
    do {
        let before = try versionThere()
        if needsInstall(before) {
            guard let script = app.installScript() else {
                return failed("install MyTokens", "this Mac's MyTokens has no install script to send\n")
            }
            let installed = try run(remoteInstallCommand, stdin: script)
            guard installed.exitCode == 0 else { return failed("install MyTokens", installed.stderr) }
            let after = try versionThere()
            guard let after, !needsInstall(after) else {
                return failed("install MyTokens", "\(host) runs \(after ?? "no MyTokens") after installing, not \(app.version ?? "a release")\n")
            }
            lines.append(before.map { "upgraded MyTokens \($0) to \(after)" } ?? "installed MyTokens \(after)")
        } else {
            lines.append("MyTokens \(before!) is installed")
        }
    } catch let failure as CommandResult {
        return failed("install MyTokens", failure.stderr)
    } catch {
        return failed("install MyTokens", "\(error)\n")
    }

    // 2. The role, then selftest.
    do {
        let role = try run(remoteSetRoleCommand)
        guard role.exitCode == 0 else { return failed("set the role", role.stderr) }
        lines.append("role server")
        let selftest = try run(remoteSelftestCommand)
        guard selftest.exitCode == 0 else { return failed("pass selftest", selftest.stdout + selftest.stderr) }
        lines.append("selftest passed")
    } catch {
        return failed("set the role", "\(error)\n")
    }

    // 3. The first Sync.
    let synced = sync(with: host, store: store, via: remote, now: now)
    lines += synced.stdout.split(separator: "\n").map(String.init)
    guard synced.exitCode == 0 else { return failed("sync", synced.stderr) }

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
func serverRm(_ host: String, store: SecretStore, list: ServerList, via remote: Remote, now: Date) -> CommandResult {
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
        return CommandResult(stdout: emptied.stdout + "removed \(host) from the server list\n", stderr: "", exitCode: 0)
    } catch {
        return CommandResult(stdout: "", stderr: "\(error)\n", exitCode: 1)
    }
}

/// `server list`: the hosts on the Server list, one per line. Nothing secret.
func serverList(_ list: ServerList) -> CommandResult {
    do {
        let hosts = try list.read()
        if hosts.isEmpty { return CommandResult(stdout: "", stderr: "no servers on the server list\n", exitCode: 0) }
        return CommandResult(stdout: hosts.map { $0 + "\n" }.joined(), stderr: "", exitCode: 0)
    } catch {
        return CommandResult(stdout: "", stderr: "\(error)\n", exitCode: 1)
    }
}
