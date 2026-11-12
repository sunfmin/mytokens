import XCTest

// A job on a Server asks for a Secret the Server lacks (sunfmin/control#744): `get`/`env`
// still exit non-zero, but say why, name the `put … --level server` line to run on a
// personal Mac, and push it once an hour through the Server's own `bark` Secret.
final class MissTests: XCTestCase {
    private var store = InMemorySecretStore()
    private var bark = RecordingBarkTransport()
    private var ledger = MemoryPushLedger()
    private var clock = Date(timeIntervalSince1970: 1_794_441_600)   // 2026-11-12 00:00 UTC

    override func setUp() {
        store = InMemorySecretStore()
        bark = RecordingBarkTransport()
        ledger = MemoryPushLedger()
        clock = Date(timeIntervalSince1970: 1_794_441_600)
    }

    private func run(_ argv: [String], role: HostRole = .server, input: String? = nil) -> CommandResult {
        runCommand(argv, Dependencies(role: InMemoryHostRoleSetting(role), store: { [store] _ in store },
                                      input: { _ in CannedSecretInput(value: input) }, remote: RecordingRemote(),
                                      stdin: { Data() }, now: { [clock] in clock }, hostName: { "mini-jp" },
                                      bark: bark, pushLedger: ledger))
    }

    private func storeBark(_ value: String = "BarkKey123") {
        _ = run(["put", "bark", "--description", "push to Felix's phone"], input: value)
    }

    func testMissOnAServerSaysWhyAndNamesTheLineToRun() {
        let r = run(["get", "deploy"])
        XCTAssertNotEqual(r.exitCode, 0)
        XCTAssertEqual(r.stdout, "")
        XCTAssertTrue(r.stderr.contains("deploy/default"), r.stderr)
        XCTAssertTrue(r.stderr.contains("not on this server (mini-jp)"), r.stderr)
        XCTAssertTrue(r.stderr.contains("only server-level secrets, synced from your personal Macs"), r.stderr)
        XCTAssertTrue(r.stderr.contains("\n  mytokens put deploy --level server\n"), r.stderr)
        XCTAssertTrue(r.stderr.contains("mytokens sync mini-jp"), r.stderr)
    }

    func testMissNamesANonDefaultAccount() {
        let r = run(["get", "cloudflare", "--account", "work"])
        XCTAssertTrue(r.stderr.contains("mytokens put cloudflare --account work --level server"), r.stderr)
    }

    func testEnvMissOnAServerSaysTheSame() {
        let r = run(["env", "llm"])
        XCTAssertNotEqual(r.exitCode, 0)
        XCTAssertEqual(r.stdout, "")
        XCTAssertTrue(r.stderr.contains("mytokens put llm --level server"), r.stderr)
    }

    func testMissWithABarkSecretPushesOnce() {
        storeBark()
        let r = run(["get", "deploy"])
        XCTAssertNotEqual(r.exitCode, 0)
        XCTAssertEqual(bark.pushes.count, 1)
        let push = bark.pushes[0]
        XCTAssertEqual(push.url.absoluteString, "https://api.day.app/BarkKey123")
        XCTAssertTrue(push.title.contains("mini-jp") && push.title.contains("deploy/default"), push.title)
        XCTAssertTrue(push.body.contains("mytokens put deploy --level server"), push.body)
        XCTAssertTrue(push.body.contains("mytokens sync mini-jp"), push.body)
        XCTAssertTrue(r.stderr.contains("Told you through Bark"), r.stderr)
    }

    func testMissPushesAtMostOncePerSecretPerHour() {
        storeBark()
        _ = run(["get", "deploy"])
        _ = run(["get", "deploy"])
        _ = run(["env", "deploy"])
        XCTAssertEqual(bark.pushes.count, 1)

        _ = run(["get", "other"])                    // another Secret has its own hour
        XCTAssertEqual(bark.pushes.count, 2)

        clock += 3599
        XCTAssertTrue(run(["get", "deploy"]).stderr.contains("within the last hour"))
        XCTAssertEqual(bark.pushes.count, 2)
        clock += 1
        _ = run(["get", "deploy"])
        XCTAssertEqual(bark.pushes.count, 3)
    }

    func testMissWithoutABarkSecretOnlyPrints() {
        let r = run(["get", "deploy"])
        XCTAssertTrue(bark.pushes.isEmpty)
        XCTAssertTrue(ledger.pushed.isEmpty)
        XCTAssertTrue(r.stderr.contains("mytokens put deploy --level server"))
    }

    func testAFailedPushStillPrintsTheMessage() {
        storeBark()
        bark.failure = BarkError(description: "offline")
        let r = run(["get", "deploy"])
        XCTAssertNotEqual(r.exitCode, 0)
        XCTAssertTrue(r.stderr.contains("mytokens put deploy --level server"))
        XCTAssertTrue(r.stderr.contains("Bark push failed (offline)"), r.stderr)
    }

    func testAHeldSecretIsUntouched() {
        storeBark()
        _ = run(["put", "deploy"], input: "tok")
        let r = run(["get", "deploy"])
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.stdout, "tok")
        XCTAssertEqual(r.stderr, "")
        XCTAssertTrue(bark.pushes.isEmpty)
    }

    func testAMissingFieldIsNotAMiss() {
        storeBark()
        _ = runCommand(["put", "aws", "--fields", "A"],
                       Dependencies(role: InMemoryHostRoleSetting(.server), store: { [store] _ in store },
                                    input: { _ in CannedSecretInput(values: ["A": "a"]) }, remote: RecordingRemote(),
                                    stdin: { Data() }))
        let r = run(["get", "aws", "--field", "B"])
        XCTAssertNotEqual(r.exitCode, 0)
        XCTAssertFalse(r.stderr.contains("--level server"))
        XCTAssertTrue(bark.pushes.isEmpty)
    }

    func testMissOnAPersonalMacIsUnchanged() {
        _ = run(["put", "bark"], role: .personal, input: "BarkKey123")
        let get = run(["get", "deploy"], role: .personal)
        XCTAssertNotEqual(get.exitCode, 0)
        XCTAssertEqual(get.stderr, "no secret for deploy/default\n")
        let env = run(["env", "llm"], role: .personal)
        XCTAssertEqual(env.stderr, "no secret for llm/default\n")
        XCTAssertTrue(bark.pushes.isEmpty)
    }

    func testTheBarkSecretMissingIsNotPushedWithItself() {
        let r = run(["get", "bark"])
        XCTAssertNotEqual(r.exitCode, 0)
        XCTAssertTrue(r.stderr.contains("mytokens put bark --level server"))
        XCTAssertTrue(bark.pushes.isEmpty)
    }

    // ── Reading the bark Secret ───────────────────────────────────────────────

    func testBarkTargetForms() {
        func url(_ s: SecretValue) -> String? { BarkTarget.url(from: s)?.absoluteString }
        XCTAssertEqual(url(SecretValue(single: "Abc123")), "https://api.day.app/Abc123")
        XCTAssertEqual(url(SecretValue(single: "https://bark.example.com/Abc123")), "https://bark.example.com/Abc123")
        XCTAssertEqual(url(SecretValue(single: "https://api.day.app/Abc123\n")), "https://api.day.app/Abc123")
        XCTAssertEqual(url(SecretValue(fields: [(label: "Device Key", value: "K1")])), "https://api.day.app/K1")
        XCTAssertEqual(url(SecretValue(fields: [(label: "server", value: "https://b.example/"), (label: "key", value: "K2")])),
                       "https://b.example/K2")
        XCTAssertEqual(url(SecretValue(fields: [(label: "URL", value: "https://b.example/K3")])), "https://b.example/K3")
        XCTAssertNil(url(SecretValue(single: "not a key")))
    }

    func testAnUnreadableBarkSecretPushesNothingAndSaysSo() {
        storeBark("not a key")
        let r = run(["get", "deploy"])
        XCTAssertTrue(bark.pushes.isEmpty)
        XCTAssertTrue(r.stderr.contains("not a device key or push URL"), r.stderr)
    }

    // ── The file ledger ────────────────────────────────────────────────────────

    func testFileLedgerClaimsOncePerInterval() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = FilePushLedger(url: dir.appendingPathComponent("miss-pushes.json"))
        let t = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(ledger.claim("a/default", now: t, interval: 3600))
        XCTAssertFalse(ledger.claim("a/default", now: t + 10, interval: 3600))
        XCTAssertTrue(ledger.claim("b/default", now: t + 10, interval: 3600))
        XCTAssertTrue(FilePushLedger(url: ledger.url).claim("a/default", now: t + 3600, interval: 3600))
    }
}

/// Records each Bark push; throws `failure` when set.
final class RecordingBarkTransport: BarkTransport {
    private(set) var pushes: [(url: URL, title: String, body: String)] = []
    var failure: Error?
    func push(to url: URL, title: String, body: String) throws {
        if let failure { throw failure }
        pushes.append((url, title, body))
    }
}
