import XCTest

// Background Sync (ADR-0016): a personal Mac's launchd agent runs `server sync`, which Syncs
// every listed Server — upgrading MyTokens there first when it is missing or older — each host
// on its own. A fake remote plays several Servers, each with its own store, role and version,
// driven through `runCommand`, so both ends run without ssh, launchd or a keychain.
final class BackgroundSyncTests: XCTestCase {
    /// One Server the fake remote plays.
    final class FakeServer {
        let store = InMemorySecretStore()
        let role = InMemoryHostRoleSetting(.server)
        var installed: String? = "0.2.0"
        var unreachable = false
    }

    /// Plays every Server by host name, answering each command as `server add`'s fake does.
    final class FleetRemote: Remote {
        var servers: [String: FakeServer] = [:]
        private(set) var runs: [(host: String, command: String, stdin: Data)] = []
        var onRun: (String, String) -> Void = { _, _ in }

        func run(host: String, command: String, stdin: Data) throws -> CommandResult {
            runs.append((host, command, stdin))
            onRun(host, command)
            guard let s = servers[host], !s.unreachable else {
                return CommandResult(stdout: "", stderr: "ssh: connect to host \(host) port 22: Operation timed out\n", exitCode: 255)
            }
            func there(_ argv: [String]) -> CommandResult {
                runCommand(argv, Dependencies(role: s.role, store: { _ in s.store }, input: { _ in CannedSecretInput(value: nil) },
                                              remote: self, stdin: { stdin }))
            }
            switch command {
            case remoteVersionCommand: return CommandResult(stdout: (s.installed ?? "none") + "\n", stderr: "", exitCode: 0)
            case remoteInstallCommand: s.installed = "0.2.0"; return CommandResult(stdout: "installed\n", stderr: "", exitCode: 0)
            case remoteSetRoleCommand: return there(["host", "server"])
            case remoteSelftestCommand: return there(["selftest"])
            case remoteExportCommand: return there(["get", "--unpushed"])
            case remotePutCommand: return there(["put", "--stdin"])
            default: return CommandResult(stdout: "", stderr: "unexpected \(command)\n", exitCode: 127)
            }
        }
    }

    final class RecordingAgent: BackgroundAgent {
        var installs = 0, removes = 0, kicks = 0
        func install() throws { installs += 1 }
        func remove() throws { removes += 1 }
        func kick() { kicks += 1 }
    }

    private var laptop = InMemorySecretStore()
    private var list = InMemoryServerList()
    private var state = MemoryBackgroundSyncState()
    private var agent = RecordingAgent()
    private var bark = RecordingBarkTransport()
    private var fleet = FleetRemote()
    private var clock = Date(timeIntervalSince1970: 1_794_441_600)

    override func setUp() {
        laptop = InMemorySecretStore()
        list = InMemoryServerList()
        state = MemoryBackgroundSyncState()
        agent = RecordingAgent()
        bark = RecordingBarkTransport()
        fleet = FleetRemote()
        clock = Date(timeIntervalSince1970: 1_794_441_600)
    }

    private func onLaptop(_ argv: [String], input: String? = nil, role: HostRole = .personal) -> CommandResult {
        runCommand(argv, Dependencies(role: InMemoryHostRoleSetting(role), store: { [laptop] _ in laptop },
                                      input: { _ in CannedSecretInput(value: input) }, remote: fleet,
                                      stdin: { Data() }, now: { [unowned self] in self.clock }, bark: bark,
                                      servers: list,
                                      app: { AppRelease(version: "0.2.0", installScript: { Data("#!/bin/bash\n".utf8) }) },
                                      syncState: state, agent: agent))
    }

    private func serve(_ hosts: String...) {
        for h in hosts { fleet.servers[h] = FakeServer() }
        list.hosts = hosts
    }

    private func hours(_ h: Double) { clock = clock.addingTimeInterval(h * 3600) }

    func testSyncsEveryListedServerAndRecordsWhen() {
        serve("mini", "studio")
        _ = onLaptop(["put", "deploy", "--level", "server"], input: "srv-tok")
        _ = onLaptop(["put", "bank"], input: "personal-tok")

        let r = onLaptop(["server", "sync"])
        XCTAssertEqual(r.exitCode, 0, r.stdout + r.stderr)
        XCTAssertTrue(r.stdout.contains("mini: added deploy/default\n"), r.stdout)
        XCTAssertTrue(r.stdout.contains("studio: added deploy/default\n"), r.stdout)
        for host in ["mini", "studio"] {
            XCTAssertEqual(try fleet.servers[host]!.store.get(service: "deploy", account: "default")?.loneValue, "srv-tok")
            XCTAssertNil(try fleet.servers[host]!.store.get(service: "bank", account: "default"))
        }
        XCTAssertEqual(onLaptop(["server", "list"]).stdout,
                       "mini\tlast synced \(statusTime(clock))\nstudio\tlast synced \(statusTime(clock))\n")
    }

    func testASecondRunChangesNothing() {
        serve("mini")
        _ = onLaptop(["put", "deploy", "--level", "server"], input: "srv-tok")
        _ = onLaptop(["server", "sync"])
        let again = onLaptop(["server", "sync"])
        XCTAssertEqual(again.exitCode, 0)
        XCTAssertTrue(again.stdout.contains("mini: no changes\n"), again.stdout)
    }

    func testAMissingOrOlderMyTokensIsUpgradedBeforeItsSync() {
        serve("fresh", "old", "current")
        fleet.servers["fresh"]!.installed = nil
        fleet.servers["fresh"]!.role.role = nil        // a new machine: no role yet
        fleet.servers["old"]!.installed = "0.1.9"
        _ = onLaptop(["put", "deploy", "--level", "server"], input: "srv-tok")

        let r = onLaptop(["server", "sync"])
        XCTAssertEqual(r.exitCode, 0, r.stdout + r.stderr)
        XCTAssertTrue(r.stdout.contains("fresh: installed MyTokens 0.2.0, role server, selftest passed, added deploy/default"), r.stdout)
        XCTAssertTrue(r.stdout.contains("old: upgraded MyTokens 0.1.9 to 0.2.0, role server, selftest passed, added deploy/default"), r.stdout)
        XCTAssertTrue(r.stdout.contains("current: added deploy/default"), r.stdout)
        for host in ["fresh", "old"] {
            let commands = fleet.runs.filter { $0.host == host }.map(\.command)
            XCTAssertEqual(commands, [remoteVersionCommand, remoteInstallCommand, remoteVersionCommand,
                                      remoteSetRoleCommand, remoteSelftestCommand, remoteExportCommand, remotePutCommand])
        }
        XCTAssertFalse(fleet.runs.contains { $0.host == "current" && $0.command == remoteInstallCommand })
        XCTAssertEqual(fleet.servers["fresh"]!.role.role, .server)
    }

    func testTheInstallerNeverSetsUpTheAgentOnAServer() {
        XCTAssertTrue(remoteInstallCommand.contains("MYTOKENS_AGENT=0"))
    }

    func testOneFailingHostDoesNotStopTheOthers() {
        serve("away", "mini")
        fleet.servers["away"]!.unreachable = true
        _ = onLaptop(["put", "deploy", "--level", "server"], input: "srv-tok")

        let r = onLaptop(["server", "sync"])
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertTrue(r.stdout.contains("away: failed to install MyTokens: ssh: connect to host away port 22: Operation timed out"), r.stdout)
        XCTAssertEqual(try fleet.servers["mini"]!.store.get(service: "deploy", account: "default")?.loneValue, "srv-tok")

        let listed = onLaptop(["server", "list"]).stdout
        XCTAssertTrue(listed.contains("away\tnever synced; failed to install MyTokens at \(statusTime(clock)): ssh: connect to host away"), listed)
        XCTAssertTrue(listed.contains("fix: check that away is on and reachable: ssh away true"), listed)
        XCTAssertTrue(listed.contains("mini\tlast synced \(statusTime(clock))\n"), listed)
    }

    func testAFailureAfterASuccessKeepsTheLastSuccessAndASuccessClearsIt() {
        serve("mini")
        _ = onLaptop(["server", "sync"])
        let synced = clock
        hours(1)
        fleet.servers["mini"]!.store.locked = true      // rebooted, nobody logged in yet
        _ = onLaptop(["server", "sync"])
        hours(1)
        _ = onLaptop(["server", "sync"])
        let listed = onLaptop(["server", "list"]).stdout
        XCTAssertTrue(listed.hasPrefix("mini\tlast synced \(statusTime(synced)); failed to sync at \(statusTime(clock)) (failing since \(statusTime(synced.addingTimeInterval(3600))))"), listed)
        XCTAssertTrue(listed.contains("keychain is locked"), listed)
        XCTAssertTrue(listed.contains("fix: log in once at mini after its reboot"), listed)

        fleet.servers["mini"]!.store.locked = false
        _ = onLaptop(["server", "sync"])
        XCTAssertEqual(onLaptop(["server", "list"]).stdout, "mini\tlast synced \(statusTime(clock))\n")
    }

    func testTwentyFourHoursOfFailurePushesOncePerDayThroughBark() {
        serve("mini")
        _ = onLaptop(["put", "bark"], input: "BarkKey123")
        fleet.servers["mini"]!.store.locked = true
        _ = onLaptop(["server", "sync"])
        for _ in 0..<95 { hours(0.25); _ = onLaptop(["server", "sync"]) }    // 23h45m
        XCTAssertEqual(bark.pushes.count, 0)

        hours(0.25)
        let r = onLaptop(["server", "sync"])
        XCTAssertEqual(bark.pushes.count, 1)
        XCTAssertTrue(r.stdout.contains("mini: told you through Bark"), r.stdout)
        let push = bark.pushes[0]
        XCTAssertEqual(push.url.absoluteString, "https://api.day.app/BarkKey123")
        XCTAssertEqual(push.title, "mytokens: mini has not synced for 24 hours")
        XCTAssertTrue(push.body.hasPrefix("Failed to sync: "), push.body)
        XCTAssertTrue(push.body.contains("Fix: log in once at mini after its reboot"), push.body)

        for _ in 0..<95 { hours(0.25); _ = onLaptop(["server", "sync"]) }
        XCTAssertEqual(bark.pushes.count, 1)
        hours(0.25); _ = onLaptop(["server", "sync"])
        XCTAssertEqual(bark.pushes.count, 2)
        XCTAssertEqual(bark.pushes[1].title, "mytokens: mini has not synced for 48 hours")
    }

    func testWithoutABarkSecretAFailureShowsOnlyInServerList() {
        serve("mini")
        fleet.servers["mini"]!.unreachable = true
        _ = onLaptop(["server", "sync"])
        hours(30)
        let r = onLaptop(["server", "sync"])
        XCTAssertEqual(bark.pushes.count, 0)
        XCTAssertFalse(r.stdout.contains("Bark"), r.stdout)
        XCTAssertTrue(onLaptop(["server", "list"]).stdout.contains("failed to install MyTokens"))
    }

    func testAnUndeliveredPushIsTriedAgain() {
        serve("mini")
        _ = onLaptop(["put", "bark"], input: "BarkKey123")
        fleet.servers["mini"]!.unreachable = true
        _ = onLaptop(["server", "sync"])
        hours(24)
        bark.failure = BarkError(description: "offline")
        XCTAssertTrue(onLaptop(["server", "sync"]).stdout.contains("the Bark push failed (offline)"))
        bark.failure = nil
        hours(0.25)
        _ = onLaptop(["server", "sync"])
        XCTAssertEqual(bark.pushes.count, 1)
    }

    func testNoSecretValueReachesTheOutputTheStatusOrAPush() throws {
        serve("mini", "conflicted")
        _ = onLaptop(["put", "bark"], input: "BarkKey123")
        _ = onLaptop(["put", "deploy", "--level", "server"], input: "srv-tok")
        _ = onLaptop(["put", "hook"], input: "mine-tok")
        _ = runCommand(["put", "hook"], Dependencies(role: fleet.servers["conflicted"]!.role,
                                                     store: { [fleet] _ in fleet.servers["conflicted"]!.store },
                                                     input: { _ in CannedSecretInput(value: "theirs-tok") },
                                                     remote: fleet, stdin: { Data() }))
        var said = ""
        for _ in 0..<3 { let r = onLaptop(["server", "sync"]); said += r.stdout + r.stderr; hours(24) }
        said += onLaptop(["server", "list"]).stdout
        let status = String(decoding: try JSONEncoder().encode(state.hosts), as: UTF8.self)
        XCTAssertTrue(said.contains("conflicted: failed to sync: conflict hook/default"), said)
        XCTAssertTrue(said.contains("fix: settle the conflict on this Mac"), said)
        XCTAssertFalse(bark.pushes.isEmpty)
        for value in ["srv-tok", "mine-tok", "theirs-tok", "BarkKey123"] {
            XCTAssertFalse(said.contains(value), value)
            XCTAssertFalse(status.contains(value), value)
            XCTAssertFalse(bark.pushes.contains { $0.title.contains(value) || $0.body.contains(value) }, value)
        }
    }

    func testAServerLevelChangeKicksTheAgentAndReturnsAtOnce() {
        serve("mini")
        XCTAssertEqual(onLaptop(["put", "bank"], input: "p").exitCode, 0)
        XCTAssertEqual(agent.kicks, 0)                                     // personal: nothing to sync

        XCTAssertEqual(onLaptop(["put", "deploy", "--level", "server"], input: "v1").exitCode, 0)
        XCTAssertEqual(agent.kicks, 1)
        XCTAssertTrue(state.pending)
        XCTAssertTrue(fleet.runs.isEmpty)                                  // the agent Syncs, not put

        _ = onLaptop(["put", "deploy"], input: "v2")                       // an update
        _ = onLaptop(["put", "bank", "--level", "server"])                 // raised
        _ = onLaptop(["put", "bank", "--level", "personal"])               // lowered
        _ = onLaptop(["rm", "deploy"])                                     // removed
        XCTAssertEqual(agent.kicks, 5)
        _ = onLaptop(["rm", "bank"])                                       // a personal one
        _ = onLaptop(["rm", "nothing"])                                    // nothing removed
        XCTAssertEqual(agent.kicks, 5)
        XCTAssertTrue(fleet.runs.isEmpty)
    }

    func testAChangeOnAServerKicksNothing() {
        _ = onLaptop(["put", "deploy"], input: "v", role: .server)
        XCTAssertEqual(agent.kicks, 0)
    }

    func testATriggerDuringARunRunsItAgain() {
        serve("mini")
        var exports = 0
        fleet.onRun = { [unowned self] _, command in
            if command == remoteExportCommand {
                exports += 1
                if exports == 1 { self.state.markPending() }           // a put while the run is in progress
            }
        }
        _ = onLaptop(["server", "sync"])
        XCTAssertEqual(exports, 2)
        XCTAssertFalse(state.pending)
    }

    func testPauseAndResumeArePerMac() {
        serve("mini")
        XCTAssertEqual(onLaptop(["server", "pause"]).exitCode, 0)
        XCTAssertTrue(state.paused)
        let r = onLaptop(["server", "sync"])
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertTrue(r.stdout.contains("paused on this Mac"), r.stdout)
        XCTAssertTrue(fleet.runs.isEmpty)
        XCTAssertTrue(onLaptop(["server", "list"]).stderr.contains("background sync is paused on this Mac"))

        // The other personal Mac keeps its own state, so it still runs.
        let other = MemoryBackgroundSyncState()
        _ = runCommand(["server", "sync"], Dependencies(role: InMemoryHostRoleSetting(), store: { [laptop] _ in laptop },
                                                        input: { _ in CannedSecretInput(value: nil) }, remote: fleet,
                                                        stdin: { Data() }, servers: list, syncState: other))
        XCTAssertFalse(fleet.runs.isEmpty)

        XCTAssertEqual(onLaptop(["server", "resume"]).exitCode, 0)
        XCTAssertFalse(state.paused)
        XCTAssertEqual(agent.kicks, 1)                                     // resuming catches up at once
    }

    func testBeforeTheFirstUnlockARunWaits() {
        serve("mini")
        laptop.locked = true
        let r = onLaptop(["server", "sync"])
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertTrue(r.stdout.contains("not been unlocked since it booted; waiting"), r.stdout)
        XCTAssertTrue(fleet.runs.isEmpty)
        XCTAssertTrue(state.hosts.isEmpty)
    }

    func testAHostTakenOffTheListIsForgotten() {
        serve("mini", "gone")
        _ = onLaptop(["server", "sync"])
        list.hosts = ["mini"]                                              // the other Mac ran server rm
        _ = onLaptop(["server", "sync"])
        XCTAssertEqual(Set(state.hosts.keys), ["mini"])
    }

    func testAManualSyncOfAListedHostIsItsLastSync() {
        serve("mini")
        _ = onLaptop(["sync", "mini"])
        XCTAssertEqual(state.hosts["mini"]?.lastSuccess, clock)
        _ = onLaptop(["sync", "elsewhere"])
        XCTAssertNil(state.hosts["elsewhere"])
    }

    func testOnAServerTheAgentIsRemovedAndBackgroundSyncRefused() {
        XCTAssertEqual(onLaptop(["server", "agent"]).exitCode, 0)
        XCTAssertEqual(agent.installs, 1)

        let r = onLaptop(["server", "agent"], role: .server)
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(agent.removes, 1)
        XCTAssertEqual(agent.installs, 1)
        for verb in ["sync", "pause", "resume"] {
            XCTAssertEqual(onLaptop(["server", verb], role: .server).exitCode, 64, verb)
        }
        _ = runCommand(["host", "server"], Dependencies(role: InMemoryHostRoleSetting(), store: { [laptop] _ in laptop },
                                                       input: { _ in CannedSecretInput(value: nil) }, remote: fleet,
                                                       stdin: { Data() }, agent: agent))
        XCTAssertEqual(agent.removes, 2)
    }

    func testTheLaunchdAgentRunsServerSyncEveryFifteenMinutes() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let plist = LaunchdAgent(home: home).plist
        XCTAssertEqual(plist["Label"] as? String, "com.sunfmin.mytokens.background-sync")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/Users/someone/.local/bin/mytokens", "server", "sync"])
        XCTAssertEqual(plist["StartInterval"] as? Int, 900)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(LaunchdAgent(home: home).plistURL.path,
                       "/Users/someone/Library/LaunchAgents/com.sunfmin.mytokens.background-sync.plist")
    }

    func testTheFileStateKeepsStatusPauseAndPendingPerMac() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = FileBackgroundSyncState(directory: dir)
        XCTAssertEqual(file.statuses(), [:])
        var status = HostSyncStatus()
        status.failed(StepFailure(step: "sync", why: "boom\n"), at: clock)
        try file.save(["mini": status])
        XCTAssertEqual(FileBackgroundSyncState(directory: dir).statuses(), ["mini": status])

        XCTAssertFalse(file.isPaused())
        try file.setPaused(true)
        XCTAssertTrue(FileBackgroundSyncState(directory: dir).isPaused())
        try file.setPaused(false)
        XCTAssertFalse(file.isPaused())

        XCTAssertFalse(file.takePending())
        file.markPending()
        XCTAssertTrue(file.takePending())
        XCTAssertFalse(file.takePending())

        var ran = false
        file.exclusively { ran = true }
        XCTAssertTrue(ran)
    }
}
