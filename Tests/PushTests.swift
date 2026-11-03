import XCTest

// `push <host>` makes a Server hold exactly a personal Mac's server-level Secrets
// (ADR-0010). Two Macs, each with its own in-memory store and role, joined by a fake
// remote that pipes the payload into the Server's own `put --stdin` — so every test
// exercises both ends through `runCommand`, and no keychain or SSH is touched.
final class PushTests: XCTestCase {
    private var laptop = InMemorySecretStore()
    private var server = InMemorySecretStore()
    private var remote = RecordingRemote()

    override func setUp() {
        laptop = InMemorySecretStore()
        server = InMemorySecretStore()
        remote = RecordingRemote { [unowned self] payload in self.onServer(["put", "--stdin"], stdin: payload) }
    }

    private func onLaptop(_ argv: [String], input: [String: String]? = nil) -> CommandResult {
        runCommand(argv, Dependencies(role: InMemoryHostRoleSetting(.personal), store: { [laptop] _ in laptop },
                                      input: { _ in CannedSecretInput(values: input) }, remote: remote, stdin: { Data() }))
    }

    private func onServer(_ argv: [String], input: [String: String]? = nil, stdin: Data = Data()) -> CommandResult {
        runCommand(argv, Dependencies(role: InMemoryHostRoleSetting(.server), store: { [server] _ in server },
                                      input: { _ in CannedSecretInput(values: input) }, remote: remote, stdin: { stdin }))
    }

    private func push() -> CommandResult { onLaptop(["push", "macs-Mac-Mini"]) }

    func testPushAddsServerLevelSecretsOnly() {
        _ = onLaptop(["put", "deploy", "--level", "server", "--description", "CI deploy"], input: ["": "srv-tok"])
        _ = onLaptop(["put", "llm", "--kind", "profile", "--level", "server", "--meta", #"{"ttl":1}"#,
                      "--set", "API_URL=https://x", "--fields", "API_KEY"], input: ["API_KEY": "k-123"])
        _ = onLaptop(["put", "bank"], input: ["": "personal-tok"])          // personal: never leaves

        let r = push()
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

    func testSecondPushReportsNoChanges() {
        _ = onLaptop(["put", "deploy", "--level", "server"], input: ["": "srv-tok"])
        XCTAssertEqual(push().stdout, "added deploy/default\n")
        XCTAssertEqual(push().stdout, "no changes\n")
    }

    func testPushUpdatesAChangedSecret() {
        _ = onLaptop(["put", "deploy", "--level", "server"], input: ["": "old"])
        _ = push()
        _ = onLaptop(["put", "deploy"], input: ["": "new"])
        XCTAssertEqual(push().stdout, "updated deploy/default\n")
        XCTAssertEqual(onServer(["get", "deploy"]).stdout, "new")
        _ = onLaptop(["put", "deploy", "--description", "now described"], input: ["": "new"])
        XCTAssertEqual(push().stdout, "updated deploy/default\n")
    }

    func testPushPrunesSecretsNoLongerServerLevelOrGone() {
        _ = onLaptop(["put", "a", "--level", "server"], input: ["": "a-tok"])
        _ = onLaptop(["put", "b", "--level", "server"], input: ["": "b-tok"])
        _ = push()

        _ = onLaptop(["put", "a", "--level", "personal"])     // lowered back
        _ = onLaptop(["rm", "b"])                             // gone
        XCTAssertEqual(push().stdout, "removed a/default\nremoved b/default\n")
        XCTAssertTrue(server.items.isEmpty)
    }

    func testPushNeverTouchesASecretEnteredOnTheServer() {
        XCTAssertEqual(onServer(["put", "local"], input: ["": "typed-here"]).exitCode, 0)
        XCTAssertEqual(onServer(["put", "deploy"], input: ["": "typed-here-too"]).exitCode, 0)
        _ = onLaptop(["put", "deploy", "--level", "server"], input: ["": "from-laptop"])

        let r = push()
        XCTAssertEqual(r.stdout, "kept deploy/default: entered on this server, not pushed\nno changes\n")
        XCTAssertEqual(onServer(["get", "local"]).stdout, "typed-here")
        XCTAssertEqual(onServer(["get", "deploy"]).stdout, "typed-here-too")

        _ = onLaptop(["put", "deploy", "--level", "personal"])
        _ = push()
        XCTAssertEqual(onServer(["get", "deploy"]).stdout, "typed-here-too")   // not pruned either
        XCTAssertEqual(server.items.count, 2)
    }

    func testAnEditOnTheServerKeepsThePushedMark() {
        _ = onLaptop(["put", "llm", "--level", "server", "--set", "A=1"])
        _ = push()
        _ = onServer(["put", "llm", "--set", "A=2"])
        XCTAssertEqual(push().stdout, "updated llm/default\n")
        XCTAssertEqual(onServer(["get", "llm", "--field", "A"]).stdout, "1")
    }

    func testValuesTravelOnlyInThePipe() {
        _ = onLaptop(["put", "deploy", "--level", "server"], input: ["": "VALUE-ONE"])
        _ = onLaptop(["put", "llm", "--level", "server", "--set", "URL=VALUE-TWO", "--fields", "KEY"],
                     input: ["KEY": "VALUE-THREE"])
        let r = push()
        XCTAssertEqual(remote.runs.count, 1)
        let run = remote.runs[0]
        XCTAssertEqual(run.host, "macs-Mac-Mini")
        XCTAssertEqual(run.command, remotePutCommand)
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
        _ = push()
        let payload = remote.runs[0].stdin                   // a real push payload
        let r = runCommand(["put", "--stdin"],
                           Dependencies(role: InMemoryHostRoleSetting(.personal), store: { [laptop] _ in laptop },
                                        input: { _ in CannedSecretInput(value: nil) }, remote: remote, stdin: { payload }))
        XCTAssertEqual(r.exitCode, 64)
        XCTAssertTrue(r.stderr.contains("personal Mac"))
        XCTAssertFalse(laptop.items.values.contains { $0.pushed })
    }

    func testPushIsRefusedOnAServer() {
        let r = onServer(["push", "elsewhere"])
        XCTAssertEqual(r.exitCode, 64)
        XCTAssertTrue(remote.runs.isEmpty)
    }

    func testPushRefusesAHostThatLooksLikeAnOption() {
        XCTAssertNotEqual(onLaptop(["push", "-oProxyCommand=x"]).exitCode, 0)
        XCTAssertTrue(remote.runs.isEmpty)
    }

    func testFailedSSHIsReportedAndNonZero() {
        remote.respond = { _ in CommandResult(stdout: "", stderr: "ssh: Could not resolve hostname\n", exitCode: 255) }
        let r = push()
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertTrue(r.stderr.contains("Could not resolve hostname"))
    }

    func testPutStdinRejectsAPersonalLevelSecretAndStoresNothing() {
        let bad = #"{"secrets":[{"service":"x","account":"default","kind":"static","level":"personal","fields":[{"label":"","value":"v"}]}]}"#
        let r = onServer(["put", "--stdin"], stdin: Data(bad.utf8))
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertTrue(server.items.isEmpty)
        XCTAssertEqual(onServer(["put", "--stdin"], stdin: Data("garbage".utf8)).exitCode, 1)
        XCTAssertEqual(onServer(["put", "svc", "--stdin"], stdin: Data()).exitCode, 64)
    }
}
