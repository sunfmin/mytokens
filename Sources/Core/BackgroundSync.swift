import Foundation

// Background Sync (ADR-0016): on each personal Mac a launchd agent Syncs every host on the
// Server list every 15 minutes, and right after a command here changes a `server`-level
// Secret, so a Server is never stale because nobody ran `sync`. Each run upgrades a host whose
// MyTokens is missing or older first (as `server add` does), then Syncs it; hosts are
// independent. What each host's last run did is kept per Mac, `server list` shows it, and a
// host failing for 24 hours straight is pushed through Bark once a day.

/// What this Mac knows of one host's background runs. Nothing secret: times, a step name and
/// the error Sync printed (Sync never prints a value, ADR-0012).
struct HostSyncStatus: Codable, Equatable {
    var lastSuccess: Date?
    var failedStep: String?        // set while the last run failed
    var failedError: String?
    var failingSince: Date?        // the first failure since the last success
    var lastFailure: Date?
    var lastPushed: Date?          // the last Bark push about this failure streak

    var isFailing: Bool { failedStep != nil }

    mutating func succeeded(at now: Date) {
        self = HostSyncStatus(lastSuccess: now)
    }

    mutating func failed(_ failure: StepFailure, at now: Date) {
        if !isFailing { failingSince = now; lastPushed = nil }
        failedStep = failure.step
        failedError = failure.why.trimmingCharacters(in: .whitespacesAndNewlines)
        lastFailure = now
    }
}

/// A named step that failed, and the error it relayed: `install MyTokens`, `set the role`,
/// `pass selftest`, `sync` — the steps `server add` names (ADR-0015).
struct StepFailure: Error, Equatable {
    var step: String
    var why: String
}

/// This Mac's own Background Sync state: each host's status, whether it is paused here, the
/// lock one run holds, and the mark a trigger leaves for a run in progress. Kept per Mac, not
/// in the iCloud Keychain: each personal Mac runs its own agent. Tests use the in-memory one.
protocol BackgroundSyncState {
    func statuses() -> [String: HostSyncStatus]
    func save(_ statuses: [String: HostSyncStatus]) throws
    func isPaused() -> Bool
    func setPaused(_ paused: Bool) throws
    /// Runs `body` while holding this Mac's one run lock, waiting for a run in progress.
    func exclusively(_ body: () -> Void)
    /// A trigger arrived (a `server`-level change): the run in progress, if any, runs again.
    func markPending()
    /// Whether a trigger arrived since the last call, clearing it.
    func takePending() -> Bool
}

extension BackgroundSyncState {
    func update(_ host: String, _ change: (inout HostSyncStatus) -> Void) {
        var all = statuses()
        var status = all[host] ?? HostSyncStatus()
        change(&status)
        all[host] = status
        try? save(all)
    }

    func forget(_ host: String) {
        var all = statuses()
        guard all.removeValue(forKey: host) != nil else { return }
        try? save(all)
    }
}

final class MemoryBackgroundSyncState: BackgroundSyncState {
    var hosts: [String: HostSyncStatus] = [:]
    var paused = false
    var pending = false
    init() {}
    func statuses() -> [String: HostSyncStatus] { hosts }
    func save(_ statuses: [String: HostSyncStatus]) throws { hosts = statuses }
    func isPaused() -> Bool { paused }
    func setPaused(_ paused: Bool) throws { self.paused = paused }
    func exclusively(_ body: () -> Void) { body() }
    func markPending() { pending = true }
    func takePending() -> Bool { defer { pending = false }; return pending }
}

/// Real state, under `~/Library/Application Support/mytokens/`: `background-sync.json` (each
/// host's status), `background-sync-paused` (present while paused), `background-sync.lock`
/// (flock'd by the run) and `background-sync-pending` (left by a trigger).
struct FileBackgroundSyncState: BackgroundSyncState {
    var directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/mytokens")

    private var statusURL: URL { directory.appendingPathComponent("background-sync.json") }
    private var pausedURL: URL { directory.appendingPathComponent("background-sync-paused") }
    private var lockURL: URL { directory.appendingPathComponent("background-sync.lock") }
    private var pendingURL: URL { directory.appendingPathComponent("background-sync-pending") }

    private func makeDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    private static var coder: (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(), d = JSONDecoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        d.dateDecodingStrategy = .secondsSince1970
        return (e, d)
    }

    func statuses() -> [String: HostSyncStatus] {
        guard let data = FileManager.default.contents(atPath: statusURL.path) else { return [:] }
        return (try? Self.coder.1.decode([String: HostSyncStatus].self, from: data)) ?? [:]
    }

    func save(_ statuses: [String: HostSyncStatus]) throws {
        makeDirectory()
        try Self.coder.0.encode(statuses).write(to: statusURL, options: .atomic)
    }

    func isPaused() -> Bool { FileManager.default.fileExists(atPath: pausedURL.path) }

    func setPaused(_ paused: Bool) throws {
        makeDirectory()
        if paused {
            try Data("paused\n".utf8).write(to: pausedURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: pausedURL.path) {
            try FileManager.default.removeItem(at: pausedURL)
        }
    }

    func exclusively(_ body: () -> Void) {
        makeDirectory()
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_EXLOCK, 0o600)   // waits for a run in progress
        defer { if fd >= 0 { close(fd) } }
        body()
    }

    func markPending() {
        makeDirectory()
        try? Data().write(to: pendingURL)
    }

    func takePending() -> Bool {
        (try? FileManager.default.removeItem(at: pendingURL)) != nil
    }
}

/// The launchd agent that runs `mytokens server sync`. Tests record; `.live` is launchd.
protocol BackgroundAgent {
    func install() throws       // write and (re)load it: install.sh, app upgrade, `server agent`
    func remove() throws        // a Server never runs it
    func kick()                 // run it now, without waiting for it
}

struct NoBackgroundAgent: BackgroundAgent {
    func install() throws {}
    func remove() throws {}
    func kick() {}
}

struct BackgroundAgentError: Error, CustomStringConvertible {
    var description: String
}

/// Real agent: `~/Library/LaunchAgents/com.sunfmin.mytokens.background-sync.plist`, loaded in
/// the user's GUI domain. It runs every 15 minutes (`StartInterval`; a sleeping Mac catches up
/// with one run on waking) and at load. launchd never runs two at once.
struct LaunchdAgent: BackgroundAgent {
    static let label = "com.sunfmin.mytokens.background-sync"
    static let interval = 15 * 60

    var home = FileManager.default.homeDirectoryForCurrentUser

    var plistURL: URL { home.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist") }
    var logURL: URL { home.appendingPathComponent("Library/Logs/mytokens/background-sync.log") }
    private var domain: String { "gui/\(getuid())" }

    /// The agent's definition. It runs the `mytokens` link install.sh keeps current, so an app
    /// upgrade needs no change here. Its log holds what `server sync` prints: names, never values.
    var plist: [String: Any] {
        let bin = home.appendingPathComponent(".local/bin")
        return [
            "Label": Self.label,
            "ProgramArguments": [bin.appendingPathComponent("mytokens").path, "server", "sync"],
            "StartInterval": Self.interval,
            "RunAtLoad": true,
            "ProcessType": "Background",
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
            "EnvironmentVariables": ["PATH": "\(bin.path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"],
        ]
    }

    @discardableResult
    private func launchctl(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (-1, "launchctl did not run") }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, text)
    }

    func install() throws {
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        launchctl(["bootout", "\(domain)/\(Self.label)"])          // an older definition, if loaded
        let (status, text) = launchctl(["bootstrap", domain, plistURL.path])
        guard status == 0 else {
            throw BackgroundAgentError(description: "launchctl bootstrap \(domain) failed (\(status)): \(text.trimmingCharacters(in: .whitespacesAndNewlines)); it loads at your next login")
        }
    }

    func remove() throws {
        launchctl(["bootout", "\(domain)/\(Self.label)"])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    func kick() {
        launchctl(["kickstart", "\(domain)/\(Self.label)"])        // a running agent is left to finish
    }
}

/// A `server`-level change on this personal Mac: mark it for a run in progress, and start the
/// agent. Returns at once; the Syncs run in the agent.
func triggerBackgroundSync(_ deps: Dependencies) {
    deps.syncState.markPending()
    deps.agent.kick()
}

/// `yyyy-MM-dd HH:mm`, this Mac's time zone: when a host last synced or failed.
func statusTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: date)
}

/// An error on one line, for `server list` and Bark.
private func oneLine(_ s: String) -> String {
    s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }.joined(separator: " — ")
}

/// The line that fixes a failure, where it is known.
func fixLine(host: String, _ failure: StepFailure) -> String {
    let why = failure.why
    if why.contains("keychain is locked") {
        return "log in once at \(host) after its reboot (at the Mac or over Screen Sharing)"
    }
    let unreachable = ["Could not resolve hostname", "Connection refused", "timed out", "No route to host",
                       "Host is down", "Network is unreachable", "Connection closed", "Connection reset"]
    if unreachable.contains(where: why.contains) {
        return "check that \(host) is on and reachable: ssh \(shellWord(host)) true"
    }
    if why.contains("Permission denied") || why.contains("Host key verification failed") {
        return "make ssh \(shellWord(host)) log in without a prompt (your ssh key, known_hosts), then: mytokens server add \(shellWord(host))"
    }
    if failure.step == "sync", why.contains("conflict ") {
        return "settle the conflict on this Mac (rm one of the two), then: mytokens sync \(shellWord(host))"
    }
    return "mytokens server add \(shellWord(host))"
}

/// How `server list` shows one host.
func describeStatus(_ status: HostSyncStatus?) -> String {
    guard let status else { return "not synced yet" }
    let last = status.lastSuccess.map { "last synced \(statusTime($0))" } ?? "never synced"
    guard status.isFailing, let step = status.failedStep else { return last }
    var text = "\(last); failed to \(step)"
    if let at = status.lastFailure { text += " at \(statusTime(at))" }
    if let since = status.failingSince, let at = status.lastFailure, at > since {
        text += " (failing since \(statusTime(since)))"
    }
    if let error = status.failedError, !error.isEmpty { text += ": " + oneLine(error) }
    return text
}

/// Upgrade `host` when its MyTokens is missing or older than this Mac's — as `server add`'s
/// first step. Returns what it did, and whether it installed.
func installIfNeeded(on host: String, via remote: Remote, app: AppRelease) throws -> (line: String, installed: Bool) {
    func versionThere() throws -> String? {
        let r = try remote.run(host: host, command: remoteVersionCommand, stdin: Data())
        guard r.exitCode == 0 else { throw StepFailure(step: "install MyTokens", why: r.stderr) }
        let v = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty || v == "none" ? nil : v
    }
    func needsInstall(_ there: String?) -> Bool {
        guard let there else { return true }
        return app.version.map { isOlder(there, than: $0) } ?? false
    }
    do {
        let before = try versionThere()
        guard needsInstall(before) else { return ("MyTokens \(before!) is installed", false) }
        guard let script = app.installScript() else {
            throw StepFailure(step: "install MyTokens", why: "this Mac's MyTokens has no install script to send\n")
        }
        let installed = try remote.run(host: host, command: remoteInstallCommand, stdin: script)
        guard installed.exitCode == 0 else { throw StepFailure(step: "install MyTokens", why: installed.stderr) }
        let after = try versionThere()
        guard let after, !needsInstall(after) else {
            throw StepFailure(step: "install MyTokens",
                              why: "\(host) runs \(after ?? "no MyTokens") after installing, not \(app.version ?? "a release")\n")
        }
        return (before.map { "upgraded MyTokens \($0) to \(after)" } ?? "installed MyTokens \(after)", true)
    } catch let failure as StepFailure {
        throw failure
    } catch {
        throw StepFailure(step: "install MyTokens", why: "\(error)\n")
    }
}

/// Set `host`'s role to `server` and run selftest there — `server add`'s second step.
func setRoleAndSelftest(on host: String, via remote: Remote) throws -> [String] {
    do {
        let role = try remote.run(host: host, command: remoteSetRoleCommand, stdin: Data())
        guard role.exitCode == 0 else { throw StepFailure(step: "set the role", why: role.stderr) }
        let selftest = try remote.run(host: host, command: remoteSelftestCommand, stdin: Data())
        guard selftest.exitCode == 0 else { throw StepFailure(step: "pass selftest", why: selftest.stdout + selftest.stderr) }
        return ["role server", "selftest passed"]
    } catch let failure as StepFailure {
        throw failure
    } catch {
        throw StepFailure(step: "set the role", why: "\(error)\n")
    }
}

/// One host's background run: upgrade when needed (then the role and selftest, as `server
/// add`), then Sync. What it did, or the step that failed.
func backgroundSync(host: String, store: SecretStore, via remote: Remote, app: AppRelease, now: Date)
    -> Result<[String], StepFailure> {
    var lines: [String] = []
    do {
        let release = try installIfNeeded(on: host, via: remote, app: app)
        if release.installed {
            lines.append(release.line)
            lines += try setRoleAndSelftest(on: host, via: remote)
        }
    } catch let failure as StepFailure {
        return .failure(failure)
    } catch {
        return .failure(StepFailure(step: "install MyTokens", why: "\(error)\n"))
    }
    let synced = sync(with: host, store: store, via: remote, now: now)
    let said = synced.stdout.split(separator: "\n").map(String.init)
    guard synced.exitCode == 0 else {
        // A conflict prints on stdout and exits 1 with nothing on stderr: that is the error.
        let why = synced.stderr.isEmpty ? said.filter { $0.hasPrefix("conflict ") }.joined(separator: "\n") : synced.stderr
        return .failure(StepFailure(step: "sync", why: why))
    }
    return .success(lines + said)
}

/// How long a host has failed before Bark is told, and how often after that.
let backgroundFailurePushAfter: TimeInterval = 24 * 3600

/// `server sync`: one Background Sync run over every listed host, again while triggers
/// arrived during it. Waits for a run in progress on this Mac. Does nothing while paused, or
/// while this Mac has not been unlocked since it booted (ADR-0011): the next run catches up.
func runBackgroundSync(store: SecretStore, deps: Dependencies) -> CommandResult {
    let state = deps.syncState
    var out = "", err = "", failed = false
    repeat {
        state.exclusively {
            _ = state.takePending()
            let r = backgroundSyncOnce(store: store, deps: deps)
            out += r.stdout
            err += r.stderr
            failed = failed || r.exitCode != 0
        }
    } while state.takePending()
    return CommandResult(stdout: out, stderr: err, exitCode: failed ? 1 : 0)
}

private func backgroundSyncOnce(store: SecretStore, deps: Dependencies) -> CommandResult {
    let state = deps.syncState
    let now = deps.now()
    let stamp = "background sync \(statusTime(now))"
    if state.isPaused() {
        return CommandResult(stdout: "\(stamp): paused on this Mac (mytokens server resume)\n", stderr: "", exitCode: 0)
    }
    let hosts: [String]
    do {
        _ = try store.list()
        hosts = try deps.servers.read()
    } catch StoreError.locked {
        return CommandResult(stdout: "\(stamp): this Mac has not been unlocked since it booted; waiting\n", stderr: "", exitCode: 0)
    } catch {
        return CommandResult(stdout: "", stderr: "\(stamp): cannot read the server list: \(error)\n", exitCode: 1)
    }
    let remote = deps.backgroundRemote ?? deps.remote
    let app = deps.app()
    var all = state.statuses().filter { hosts.contains($0.key) }   // forget hosts taken off the list
    var lines = ["\(stamp): \(hosts.isEmpty ? "no servers on the server list" : hosts.joined(separator: ", "))"]
    var anyFailed = false
    for host in hosts {
        var status = all[host] ?? HostSyncStatus()
        switch backgroundSync(host: host, store: store, via: remote, app: app, now: now) {
        case .success(let did):
            status.succeeded(at: now)
            lines.append("\(host): " + did.joined(separator: ", "))
        case .failure(let failure):
            anyFailed = true
            status.failed(failure, at: now)
            lines.append("\(host): failed to \(failure.step): \(oneLine(failure.why))")
            if let pushed = pushFailure(host: host, status: status, failure: failure, store: store, deps: deps, now: now) {
                if pushed.delivered { status.lastPushed = now }
                lines.append("\(host): \(pushed.said)")
            }
        }
        all[host] = status
    }
    try? state.save(all)
    return CommandResult(stdout: lines.map { $0 + "\n" }.joined(), stderr: "", exitCode: anyFailed ? 1 : 0)
}

/// The Bark push for a host failing 24 hours straight, once a day, when this Mac has a `bark`
/// Secret. Returns what to log about it, or nil when nothing is due; an undelivered push is
/// tried again at the next run.
private func pushFailure(host: String, status: HostSyncStatus, failure: StepFailure, store: SecretStore,
                         deps: Dependencies, now: Date) -> (said: String, delivered: Bool)? {
    guard let since = status.failingSince, now.timeIntervalSince(since) >= backgroundFailurePushAfter else { return nil }
    if let last = status.lastPushed, now.timeIntervalSince(last) < backgroundFailurePushAfter { return nil }
    guard let bark = (try? store.get(service: BarkTarget.service, account: "default")).flatMap({ $0 }),
          let url = BarkTarget.url(from: bark) else { return nil }
    let hours = Int(now.timeIntervalSince(since) / 3600)
    let title = "mytokens: \(host) has not synced for \(hours) hours"
    var why = oneLine(failure.why)
    if why.count > 300 { why = String(why.prefix(300)) + "…" }
    let body = "Failed to \(failure.step): \(why). Fix: \(fixLine(host: host, failure))"
    do {
        try deps.bark.push(to: url, title: title, body: body)
        return ("told you through Bark", true)
    } catch {
        return ("the Bark push failed (\(error))", false)
    }
}
