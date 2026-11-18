import XCTest

// Inside a factorium worker (mytokens#15), every command that writes a 1Password vault or Syncs
// hosts with the real store is refused before any token is read or anything written, and the
// refusal names the scratch check. Outside a worker the same commands run as before.
final class WorkerGuardTests: XCTestCase {
    /// Records every `op` call; answers an empty vault.
    final class RecordingOP: OnePasswordCLI {
        private(set) var calls: [[String]] = []
        func run(_ args: [String], stdin: Data, token: String) throws -> CommandResult {
            calls.append(args)
            return CommandResult(stdout: args.prefix(2) == ["item", "list"] ? "[]" : "", stderr: "", exitCode: 0)
        }
    }

    /// The store, counting each value read (a token is read with `get`) and each write.
    final class WatchedStore: SecretStore {
        let inner = InMemorySecretStore()
        private(set) var gets = 0, writes = 0
        func upsert(service: String, account: String, secret: SecretValue, kind: String, meta: Any?, description: String?,
                    level: Level, marks: SyncMarks) throws {
            writes += 1
            try inner.upsert(service: service, account: account, secret: secret, kind: kind, meta: meta,
                             description: description, level: level, marks: marks)
        }
        func get(service: String, account: String) throws -> SecretValue? { gets += 1; return try inner.get(service: service, account: account) }
        func list() throws -> [SecretRecord] { try inner.list() }
        func delete(service: String, account: String) throws -> Bool { writes += 1; return try inner.delete(service: service, account: account) }
    }

    private var store = WatchedStore()
    private var op = RecordingOP()
    private var remote = RecordingRemote()
    private var agent = BackgroundSyncTests.RecordingAgent()
    private var servers = InMemoryServerList()
    private var vaults = InMemoryServerList()

    override func setUpWithError() throws {
        store = WatchedStore(); op = RecordingOP(); remote = RecordingRemote(); agent = .init()
        servers = InMemoryServerList(); vaults = InMemoryServerList()
        servers.hosts = ["mini-jp"]; vaults.hosts = ["devbox"]
        for (service, level) in [(onePasswordTokenService, Level.personal), ("bark", .server), ("notes", .personal)] {
            try store.inner.upsert(service: service, account: "default", secret: SecretValue(single: "v-\(service)"), kind: "static",
                                   meta: nil, description: nil, level: level, marks: SyncMarks())
        }
    }

    private func run(_ argv: [String], inWorker: Bool = true, input: String? = "new") -> CommandResult {
        var d = Dependencies(store: store, input: CannedSecretInput(value: input))
        d.remote = remote; d.backgroundRemote = remote; d.agent = agent
        d.servers = servers; d.vaults = vaults; d.onepassword = op
        d.inWorker = inWorker
        return runCommand(argv, d)
    }

    /// Refused, naming the scratch check, with no token read, nothing written, nothing reached.
    private func assertRefused(_ argv: [String], file: StaticString = #filePath, line: UInt = #line) {
        let r = run(argv)
        XCTAssertEqual(r.exitCode, 1, file: file, line: line)
        XCTAssertTrue(r.stderr.contains("factorium worker"), r.stderr, file: file, line: line)
        XCTAssertTrue(r.stderr.contains(scratchVault) && r.stderr.contains("tools/op-real-check.sh")
                      && r.stderr.contains(scratchTokenService), r.stderr, file: file, line: line)
        XCTAssertEqual(store.gets, 0, "a token or value was read", file: file, line: line)
        XCTAssertEqual(store.writes, 0, "the store was written", file: file, line: line)
        XCTAssertEqual(op.calls, [], file: file, line: line)
        XCTAssertEqual(remote.runs.count, 0, file: file, line: line)
        XCTAssertEqual(agent.kicks, 0, file: file, line: line)
        XCTAssertEqual(servers.hosts, ["mini-jp"], file: file, line: line)
        XCTAssertEqual(servers.writes, 0, file: file, line: line)
        XCTAssertEqual(vaults.hosts, ["devbox"], file: file, line: line)
        XCTAssertEqual(vaults.writes, 0, file: file, line: line)
    }

    func testOnePasswordAddIsRefused() { assertRefused(["onepassword", "add", "devbox"]) }
    func testOnePasswordRmIsRefused() { assertRefused(["onepassword", "rm", "devbox"]) }
    func testOnePasswordKeepIsRefused() { assertRefused(["onepassword", "keep", "devbox", "stripe", "mac"]) }
    func testServerSyncIsRefused() { assertRefused(["server", "sync"]) }
    func testServerAddIsRefused() { assertRefused(["server", "add", "mini-jp"]) }
    func testServerRmIsRefused() { assertRefused(["server", "rm", "mini-jp"]) }
    func testSyncOfAHostIsRefused() { assertRefused(["sync", "mini-jp"]) }

    /// A `put`/`rm` of a `server`-level Secret would start Background Sync: refused before the write.
    func testPutOfAServerLevelSecretIsRefused() { assertRefused(["put", "bark"]) }
    func testPutThatMakesASecretServerLevelIsRefused() { assertRefused(["put", "notes", "--level", "server"]) }
    func testNewServerLevelSecretIsRefused() { assertRefused(["put", "fresh", "--level", "server"]) }
    func testRmOfAServerLevelSecretIsRefused() { assertRefused(["rm", "bark"]) }

    /// A personal Secret never starts Background Sync: a worker may still put and rm it.
    func testPersonalSecretsStillWork() throws {
        XCTAssertEqual(run(["put", "notes"]).exitCode, 0)
        XCTAssertEqual(run(["rm", "notes"]).exitCode, 0)
        XCTAssertEqual(agent.kicks, 0)
    }

    /// Reading commands are not writes: they run in a worker.
    func testListsStillWork() {
        XCTAssertEqual(run(["server", "list"]).exitCode, 0)
        XCTAssertEqual(run(["list"]).exitCode, 0)
    }

    /// Outside a worker the same commands run: the guard is the worker's alone.
    func testOutsideAWorkerTheyRun() throws {
        XCTAssertEqual(run(["onepassword", "add", "scratch"], inWorker: false).exitCode, 0)
        XCTAssertFalse(op.calls.isEmpty)
        XCTAssertEqual(run(["put", "bark"], inWorker: false).exitCode, 0)
        XCTAssertEqual(agent.kicks, 1)
    }

    /// `.live` takes the guard from FACTORIUM_WORKER being set at all.
    func testWorkerIsReadFromTheEnvironment() {
        XCTAssertTrue(inFactoriumWorker(["FACTORIUM_WORKER": "mytokens-15-1"]))
        XCTAssertTrue(inFactoriumWorker(["FACTORIUM_WORKER": ""]))
        XCTAssertFalse(inFactoriumWorker(["PATH": "/usr/bin"]))
    }
}
