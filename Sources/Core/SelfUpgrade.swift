import Foundation

// A personal Mac installs a newer published Release itself (ADR-0023): each Background Sync
// run, before it syncs hosts, looks at the newest Release of sunfmin/mytokens at most once an
// hour, and when it is newer than the installed app runs the one installer. Servers never
// do this; they follow this Mac through `installIfNeeded` (ADR-0016).

/// Where the newest published Release's version comes from. Tests pass a fake.
protocol ReleaseSource {
    func latestVersion() throws -> String
}

/// How a newer Release is installed: the one way installs happen, `scripts/install.sh`.
protocol AppInstaller {
    func install(script: Data) throws
}

/// GitHub's "latest release" (never a draft or pre-release); its tag is `v<version>`.
struct GitHubReleaseSource: ReleaseSource {
    var repo = "sunfmin/mytokens"

    func latestVersion() throws -> String {
        let r = try runProcess("/usr/bin/curl",
                               ["-fsSL", "--max-time", "30", "-H", "Accept: application/vnd.github+json",
                                "https://api.github.com/repos/\(repo)/releases/latest"], stdin: Data())
        guard r.exitCode == 0 else {
            throw StepFailure(step: "check for a new release", why: r.stderr)
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any],
              let tag = json["tag_name"] as? String, !tag.isEmpty else {
            throw StepFailure(step: "check for a new release", why: "GitHub's answer has no tag_name\n")
        }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }
}

/// Runs install.sh (from the running app) with `MYTOKENS_AGENT=0`: the agent that runs this
/// very process must not be reloaded under it, and its plist runs the `~/.local/bin` link, so
/// the upgrade needs no change to it. The installer's selftest runs.
struct ScriptAppInstaller: AppInstaller {
    func install(script: Data) throws {
        var env = ProcessInfo.processInfo.environment
        env["MYTOKENS_AGENT"] = "0"
        let r = try runProcess("/bin/bash", ["-s"], environment: env, stdin: script)
        guard r.exitCode == 0 else {
            throw StepFailure(step: "install the new release", why: r.stderr.isEmpty ? r.stdout : r.stderr)
        }
    }
}

/// The key the release check's status is kept under in Background Sync's state.
let releaseStatusKey = "release:sunfmin/mytokens"

/// At most one check per hour.
let releaseCheckEvery: TimeInterval = 3600

/// One run's release check. Returns the lines to log, whether it failed, and updates `status`.
/// A failure is kept in the status (`server list` shows it) and never stops the host syncs.
func upgradeThisMacIfNewer(status: inout HostSyncStatus, deps: Dependencies, now: Date) -> (lines: [String], failed: Bool) {
    guard let releases = deps.releases, let installer = deps.installer else { return ([], false) }
    let last = [status.lastSuccess, status.lastFailure].compactMap { $0 }.max()
    if let last, now.timeIntervalSince(last) < releaseCheckEvery, now >= last { return ([], false) }
    let app = deps.app()
    do {
        let latest = try releases.latestVersion()
        guard let installed = app.version, isOlder(installed, than: latest) else {
            status.succeeded(at: now)
            return ([], false)
        }
        guard let script = app.installScript() else {
            throw StepFailure(step: "install the new release", why: "this Mac's MyTokens has no install script\n")
        }
        try installer.install(script: script)
        status.succeeded(at: now)
        return (["upgraded MyTokens on this Mac \(installed) to \(latest)"], false)
    } catch let failure as StepFailure {
        status.failed(failure, at: now)
        return (["this Mac: failed to \(failure.step): \(failure.why.split(whereSeparator: \.isNewline).joined(separator: " — "))"], true)
    } catch {
        let failure = StepFailure(step: "check for a new release", why: "\(error)\n")
        status.failed(failure, at: now)
        return (["this Mac: failed to \(failure.step): \(error)"], true)
    }
}
