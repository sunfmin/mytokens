import XCTest

// `sync <host>` brings a personal Mac and one Server into agreement (ADR-0012): it adopts
// the Secrets entered on the Server, then makes the Server hold exactly the personal Mac's
// server-level Secrets. Two Macs, each with its own in-memory store and role, joined by a
// fake remote that runs the Server's own `get --unpushed` and `put --stdin` — so every
// test exercises both ends through `runCommand`, and no keychain or SSH is touched.
final class SyncTests: XCTestCase {
    private var laptop = InMemorySecretStore()
    private var server = InMemorySecretStore()
    private var remote = RecordingRemote()
    private let today = Date(timeIntervalSince1970: 1_793_707_200)   // 2026-11-03 12:00 UTC

    override func setUp() {
        laptop = InMemorySecretStore()
        server = InMemorySecretStore()
        remote = RecordingRemote { [unowned self] command, payload in
            switch command {
            case remoteExportCommand: return self.onServer(["get", "--unpushed"])
            case remotePutCommand: return self.onServer(["put", "--stdin"], stdin: payload)
            default: return CommandResult(stdout: "", stderr: "unexpected command \(command)\n", exitCode: 127)
            }
        }
    }

    private func onLaptop(_ argv: [String], input: [String: String]? = nil) -> CommandResult {
        runCommand(argv, Dependencies(role: InMemoryHostRoleSetting(.personal), store: { [laptop] _ in laptop },
                                      input: { _ in CannedSecretInput(values: input) }, remote: remote,
                                      stdin: { Data() }, now: { [today] in today }))
    }

    private func onServer(_ argv: [String], input: [String: String]? = nil, stdin: Data = Data()) -> CommandResult {
        runCommand(argv, Dependencies(role: InMemoryHostRoleSetting(.server), store: { [server] _ in server },
                                      input: { _ in CannedSecretInput(values: input) }, remote: remote, stdin: { stdin }))
    }

    private func sync() -> CommandResult { onLaptop(["sync", "macs-Mac-Mini"]) }
    private var note: String { adoptionNote(host: "macs-Mac-Mini", on: today) }

    func testSyncAddsServerLevelSecretsOnly() {
        _ = onLaptop(["put", "deploy", "--level", "server", "--description", "CI deploy"], input: ["": "srv-tok"])
        _ = onLaptop(["put", "llm", "--kind", "profile", "--level", "server", "--meta", #"{"ttl":1}"#,
                      "--set", "API_URL=https://x", "--fields", "API_KEY"], input: ["API_KEY": "k-123"])
        _ = onLaptop(["put", "bank"], input: ["": "personal-tok"])          // personal: never leaves

        let r = sync()
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        XCTAssertEqual(r.stdout, "added deploy/default\nadded llm/default\n")

        XCTAssertEqual(onServer(["get", "deploy"]).stdout, "srv-tok")
        XCTAssertEqual(onServer(["env", "llm"]).stdout, "export API_URL='https://x'\nexport API_KEY='k-123'\n")
        XCTAssertNil(try server.get(service: "bank", account: "default"))
        let llm = try! server.list().first { $0.service == "llm" }!
        XCTAssertEqual(llm.kind, "profile")
        XCTAssertEqual(llm.meta, #"{"ttl":1}"#)
        XCTAssertEqual(llm.level, .server)
        XCTAssertTrue(llm.pushed)
        XCTAssertEqual(try server.list().first { $0.service == "deploy" }?.description, "CI deploy")
    }

    func testSecondSyncReportsNoChanges() {
        _ = onLaptop(["put", "deploy", "--level", "server"], input: ["": "srv-tok"])
        XCTAssertEqual(sync().stdout, "added deploy/default\n")
        XCTAssertEqual(sync().stdout, "no changes\n")
    }

    func testSyncUpdatesAChangedSecret() {
        _ = onLaptop(["put", "deploy", "--level", "server"], input: ["": "old"])
        _ = sync()
        _ = onLaptop(["put", "deploy"], input: ["": "new"])
        XCTAssertEqual(sync().stdout, "updated deploy/default\n")
        XCTAssertEqual(onServer(["get", "deploy"]).stdout, "new")
        _ = onLaptop(["put", "deploy", "--description", "now described"], input: ["": "new"])
        XCTAssertEqual(sync().stdout, "updated deploy/default\n")
    }

    func testSyncPrunesSecretsNoLongerServerLevelOrGone() {
        _ = onLaptop(["put", "a", "--level", "server"], input: ["": "a-tok"])
        _ = onLaptop(["put", "b", "--level", "server"], input: ["": "b-tok"])
        _ = sync()

        _ = onLaptop(["put", "a", "--level", "personal"])     // lowered back
        _ = onLaptop(["rm", "b"])                             // gone
        XCTAssertEqual(sync().stdout, "removed a/default\nremoved b/default\n")
        XCTAssertTrue(server.items.isEmpty)
    }

    func testAnEditOnTheServerKeepsThePushedMark() {
        _ = onLaptop(["put", "llm", "--level", "server", "--set", "A=1"])
        _ = sync()
        _ = onServer(["put", "llm", "--set", "A=2"])
        XCTAssertEqual(sync().stdout, "updated llm/default\n")
        XCTAssertEqual(onServer(["get", "llm", "--field", "A"]).stdout, "1")
    }

    func testValuesTravelOnlyInThePipe() {
        _ = onLaptop(["put", "deploy", "--level", "server"], input: ["": "VALUE-ONE"])
        _ = onLaptop(["put", "llm", "--level", "server", "--set", "URL=VALUE-TWO", "--fields", "KEY"],
                     input: ["KEY": "VALUE-THREE"])
        let r = sync()
        XCTAssertEqual(remote.runs.map(\.command), [remoteExportCommand, remotePutCommand])
        let run = remote.runs[1]
        XCTAssertEqual(run.host, "macs-Mac-Mini")
        let piped = String(decoding: run.stdin, as: UTF8.self)
        for value in ["VALUE-ONE", "VALUE-TWO", "VALUE-THREE"] {
            XCTAssertTrue(piped.contains(value))                     // in the pipe…
            XCTAssertFalse(run.host.contains(value))                 // …never in argv
            XCTAssertFalse(run.command.contains(value))
            XCTAssertFalse(r.stdout.contains(value) || r.stderr.contains(value))   // …or printed
        }
    }

    func testPutStdinIsRefusedOnAPersonalMac() {
        _ = onLaptop(["put", "deploy", "--level", "server"], input: ["": "tok"])
        _ = sync()
        let payload = remote.runs[1].stdin                   // a real sync payload
        let r = runCommand(["put", "--stdin"],
                           Dependencies(role: InMemoryHostRoleSetting(.personal), store: { [laptop] _ in laptop },
                                        input: { _ in CannedSecretInput(value: nil) }, remote: remote, stdin: { payload }))
        XCTAssertEqual(r.exitCode, 64)
        XCTAssertTrue(r.stderr.contains("personal Mac"))
        XCTAssertFalse(laptop.items.values.contains { $0.pushed })
    }

    func testSyncIsRefusedOnAServer() {
        let r = onServer(["sync", "elsewhere"])
        XCTAssertEqual(r.exitCode, 64)
        XCTAssertTrue(remote.runs.isEmpty)
    }

    func testSyncRefusesAHostThatLooksLikeAnOption() {
        XCTAssertNotEqual(onLaptop(["sync", "-oProxyCommand=x"]).exitCode, 0)
        XCTAssertTrue(remote.runs.isEmpty)
    }

    func testFailedSSHIsReportedAndNonZero() {
        remote.respond = { _, _ in CommandResult(stdout: "", stderr: "ssh: Could not resolve hostname\n", exitCode: 255) }
        let r = sync()
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertTrue(r.stderr.contains("Could not resolve hostname"))
    }

    func testFailedGetUnpushedNamesAdoptAndReportsTheServerError() {
        remote.respond = { _, _ in CommandResult(stdout: "", stderr: "keychain error -61: Write permissions error.\n", exitCode: 1) }
        let r = sync()
        XCTAssertNotEqual(r.exitCode, 0)
        XCTAssertTrue(r.stderr.contains("adopt"), r.stderr)
        XCTAssertTrue(r.stderr.contains("keychain error -61: Write permissions error."), r.stderr)
        XCTAssertFalse(r.stdout.contains("no changes") || r.stderr.contains("no changes"))
        XCTAssertEqual(remote.runs.map(\.command), [remoteExportCommand])
    }

    func testFailedPutStdinNamesPushAndReportsTheServerErrorWithoutValues() {
        _ = onLaptop(["put", "deploy", "--level", "server"], input: ["": "VALUE-THAT-MUST-NOT-LEAK"])
        let real = remote.respond
        remote.respond = { command, payload in
            command == remotePutCommand
                ? CommandResult(stdout: "no changes\n", stderr: "keychain error -61: Write permissions error.\n", exitCode: 1)
                : real(command, payload)
        }
        let r = sync()
        XCTAssertNotEqual(r.exitCode, 0)
        XCTAssertTrue(r.stderr.contains("push"), r.stderr)
        XCTAssertTrue(r.stderr.contains("keychain error -61: Write permissions error."), r.stderr)
        XCTAssertFalse(r.stdout.contains("no changes") || r.stderr.contains("no changes"))
        XCTAssertFalse(r.stdout.contains("VALUE-THAT-MUST-NOT-LEAK") || r.stderr.contains("VALUE-THAT-MUST-NOT-LEAK"))
    }

    func testPutStdinRejectsAPersonalLevelSecretAndStoresNothing() {
        let bad = #"{"secrets":[{"service":"x","account":"default","kind":"static","level":"personal","fields":[{"label":"","value":"v"}]}]}"#
        let r = onServer(["put", "--stdin"], stdin: Data(bad.utf8))
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertTrue(server.items.isEmpty)
        XCTAssertEqual(onServer(["put", "--stdin"], stdin: Data("garbage".utf8)).exitCode, 1)
        XCTAssertEqual(onServer(["put", "svc", "--stdin"], stdin: Data()).exitCode, 64)
    }

    // MARK: adoption

    func testASecretEnteredOnTheServerIsAdoptedWhole() {
        _ = onServer(["put", "llm", "--kind", "profile", "--meta", #"{"ttl":1}"#, "--description", "agent LLM",
                      "--set", "API_URL=https://x", "--fields", "API_KEY"], input: ["API_KEY": "typed-on-server"])
        _ = onServer(["put", "bare"], input: ["": "bare-tok"])

        let r = sync()
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        XCTAssertEqual(r.stdout, "adopted bare/default\nadopted llm/default\n")

        let llm = try! laptop.list().first { $0.service == "llm" }!
        XCTAssertEqual(llm.kind, "profile")
        XCTAssertEqual(llm.meta, #"{"ttl":1}"#)
        XCTAssertEqual(llm.level, .server)
        XCTAssertFalse(llm.pushed)
        XCTAssertEqual(llm.description, "agent LLM (\(note))")
        XCTAssertEqual(note, "adopted from macs-Mac-Mini on 2026-11-03")
        XCTAssertEqual(onLaptop(["env", "llm"]).stdout, "export API_URL='https://x'\nexport API_KEY='typed-on-server'\n")
        XCTAssertEqual(onLaptop(["get", "bare"]).stdout, "bare-tok")
        XCTAssertEqual(try laptop.list().first { $0.service == "bare" }?.description, note)

        // On the Server each is now a pushed Secret like any other, with the same record.
        for r in try! server.list() {
            XCTAssertTrue(r.pushed, r.service)
            XCTAssertEqual(r.description, try! laptop.list().first { $0.service == r.service }?.description)
        }
        XCTAssertEqual(onServer(["get", "llm", "--field", "API_KEY"]).stdout, "typed-on-server")
        XCTAssertEqual(server.items.count, 2)
    }

    func testASecondSyncAfterAdoptionChangesNothing() {
        _ = onServer(["put", "local"], input: ["": "typed-here"])
        XCTAssertEqual(sync().stdout, "adopted local/default\n")
        XCTAssertEqual(sync().stdout, "no changes\n")
    }

    func testASecretRemovedHereAfterAdoptionIsRemovedFromTheServer() {
        _ = onServer(["put", "local"], input: ["": "typed-here"])
        _ = sync()
        _ = onLaptop(["rm", "local"])
        XCTAssertEqual(sync().stdout, "removed local/default\n")
        XCTAssertTrue(server.items.isEmpty)
    }

    func testASameNameSecretHereIsAConflictAndNeitherSideChanges() {
        for level in ["personal", "server"] {
            setUp()
            _ = onServer(["put", "deploy", "--description", "server's"], input: ["": "typed-on-server"])
            _ = onLaptop(["put", "deploy", "--level", level, "--description", "mine"], input: ["": "from-laptop"])
            _ = onLaptop(["put", "other", "--level", "server"], input: ["": "o"])
            let before = (snapshot(laptop), snapshot(server))

            let r = sync()
            XCTAssertEqual(r.exitCode, 1, level)
            XCTAssertEqual(r.stdout, "added other/default\n"
                           + "conflict deploy/default: entered on macs-Mac-Mini and also on this Mac; neither changed\n", level)
            // The rest of the sync went through; deploy/default is untouched on both sides.
            XCTAssertEqual(snapshot(laptop), before.0, level)
            XCTAssertEqual(snapshot(server).filter { !$0.hasPrefix("other/") }, before.1, level)
            XCTAssertEqual(sync().exitCode, 1, level)   // still left for the human
        }
    }

    func testAPushedSecretIsNeverAdopted() {
        _ = onLaptop(["put", "deploy", "--level", "server"], input: ["": "tok"])
        _ = sync()
        _ = onLaptop(["put", "deploy", "--level", "personal"])   // lowered: the Server's copy goes…
        XCTAssertEqual(sync().stdout, "removed deploy/default\n")
        XCTAssertEqual(try laptop.list().first?.level, .personal)  // …and is never brought back
        XCTAssertEqual(onServer(["get", "--unpushed"]).stdout, #"{"secrets":[]}"#)
    }

    func testAnAdoptionCutShortIsFinishedByTheNextSync() {
        _ = onServer(["put", "local"], input: ["": "typed-here"])
        let real = remote.respond
        remote.respond = { command, payload in
            command == remotePutCommand ? CommandResult(stdout: "", stderr: "ssh: connection reset\n", exitCode: 255)
                                        : real(command, payload)
        }
        let cut = sync()
        XCTAssertEqual(cut.exitCode, 1)
        XCTAssertEqual(cut.stdout, "adopted local/default\n")
        XCTAssertTrue(cut.stderr.contains("connection reset"))
        XCTAssertFalse(server.items.values.contains { $0.pushed })

        remote.respond = real
        let r = sync()
        XCTAssertEqual(r.exitCode, 0, r.stdout)
        XCTAssertEqual(r.stdout, "adopted local/default\n")
        XCTAssertTrue(server.items.values.allSatisfy { $0.pushed })
        XCTAssertEqual(sync().stdout, "no changes\n")
    }

    func testAdoptedValuesTravelOnlyInThePipe() {
        _ = onServer(["put", "local"], input: ["": "SERVER-VALUE"])
        let r = sync()
        XCTAssertTrue(remote.runs[0].stdin.isEmpty)
        for run in remote.runs { XCTAssertFalse(run.command.contains("SERVER-VALUE") || run.host.contains("SERVER-VALUE")) }
        XCTAssertFalse(r.stdout.contains("SERVER-VALUE") || r.stderr.contains("SERVER-VALUE"))
    }

    func testGetUnpushedIsRefusedOnAPersonalMac() {
        _ = onLaptop(["put", "deploy"], input: ["": "tok"])
        let r = onLaptop(["get", "--unpushed"])
        XCTAssertEqual(r.exitCode, 64)
        XCTAssertFalse(r.stdout.contains("tok"))
        XCTAssertEqual(onServer(["get", "--unpushed", "x"]).exitCode, 64)
    }

    func testPushIsGoneAndNamesSync() {
        let r = onLaptop(["push", "macs-Mac-Mini"])
        XCTAssertEqual(r.exitCode, 64)
        XCTAssertTrue(r.stderr.contains("mytokens sync <host>"))
        XCTAssertTrue(remote.runs.isEmpty)
    }

    func testPutStdinRefusesAnAdoptionNotSent() {
        let bad = #"{"secrets":[],"adopt":["x/default"]}"#
        _ = onServer(["put", "x"], input: ["": "v"])
        XCTAssertEqual(onServer(["put", "--stdin"], stdin: Data(bad.utf8)).exitCode, 1)
        XCTAssertFalse(server.items.values.contains { $0.pushed })
    }

    /// Every item of a store, byte for byte as far as a test can see: name, values, metadata.
    private func snapshot(_ store: InMemorySecretStore) -> [String] {
        try! store.list().map { r in
            let v = try! store.get(service: r.service, account: r.account)!.fields.map { "\($0.label)=\($0.value)" }
            return "\(r.service)/\(r.account) \(v) \(r.kind) \(r.meta ?? "-") \(r.description ?? "-") \(r.level) \(r.pushed)"
        }.sorted()
    }
}
