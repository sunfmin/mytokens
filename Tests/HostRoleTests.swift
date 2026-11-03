import XCTest

// The Mac's role picks the store every Secret command acts on (ADR-0010):
// personal → the iCloud Keychain, server → the login keychain. Driven through
// fakes — one in-memory store per role — so no real keychain is touched.
final class HostRoleTests: XCTestCase {
    private var personal = InMemorySecretStore()
    private var server = InMemorySecretStore()
    private var setting = InMemoryHostRoleSetting()

    override func setUp() {
        personal = InMemorySecretStore()
        server = InMemorySecretStore()
        setting = InMemoryHostRoleSetting()
    }

    private func run(_ argv: [String], input: [String: String]? = nil) -> CommandResult {
        let deps = Dependencies(role: setting,
                                store: { [personal, server] in $0 == .server ? server : personal },
                                input: CannedSecretInput(values: input),
                                remote: RecordingRemote(), stdin: { Data() })
        return runCommand(argv, deps)
    }

    func testHostDefaultsToPersonal() {
        let r = run(["host"])
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.stdout, "personal\n")
    }

    func testHostSetsAndPrintsTheRole() {
        XCTAssertEqual(run(["host", "server"]).exitCode, 0)
        XCTAssertEqual(setting.role, .server)
        XCTAssertEqual(run(["host"]).stdout, "server\n")
        XCTAssertEqual(run(["host", "personal"]).exitCode, 0)
        XCTAssertEqual(run(["host"]).stdout, "personal\n")
    }

    func testHostRefusesAnUnknownRole() {
        let r = run(["host", "laptop"])
        XCTAssertEqual(r.exitCode, 64)
        XCTAssertTrue(r.stderr.contains("'personal' or 'server'"))
        XCTAssertNil(setting.role)   // unchanged
    }

    func testPersonalMacActsOnTheICloudStore() {
        XCTAssertEqual(run(["put", "gh"], input: ["": "p-tok"]).exitCode, 0)
        XCTAssertEqual(personal.items.count, 1)
        XCTAssertEqual(server.items.count, 0)
        XCTAssertEqual(run(["get", "gh"]).stdout, "p-tok")
    }

    func testServerActsOnTheLoginStoreForEveryCommand() {
        _ = run(["put", "gh"], input: ["": "personal-tok"])          // while still personal
        XCTAssertEqual(run(["host", "server"]).exitCode, 0)

        XCTAssertEqual(run(["put", "gh"], input: ["": "server-tok"]).exitCode, 0)
        XCTAssertEqual(run(["put", "llm", "--kind", "profile", "--set", "API_URL=https://x"]).exitCode, 0)
        XCTAssertEqual(run(["get", "gh"]).stdout, "server-tok")
        XCTAssertEqual(run(["env", "llm"]).stdout, "export API_URL='https://x'\n")
        let list = run(["list"]).stdout
        XCTAssertTrue(list.contains("gh/default"))
        XCTAssertTrue(list.contains("llm/default"))
        XCTAssertEqual(run(["rm", "gh"]).exitCode, 0)

        // The personal store was never touched by the server's commands.
        XCTAssertEqual(server.items.count, 1)
        XCTAssertEqual(personal.items.count, 1)
        XCTAssertEqual(try personal.get(service: "gh", account: "default")?.loneValue, "personal-tok")
    }

    func testEverySecretStoredOnAServerIsServerLevel() {
        setting.role = .server
        XCTAssertEqual(run(["put", "gh"], input: ["": "tok"]).exitCode, 0)
        XCTAssertEqual(try server.list().first?.level, .server)
        XCTAssertTrue(run(["list"]).stdout.contains("\tserver"))

        let refused = run(["put", "gh", "--level", "personal"])
        XCTAssertEqual(refused.exitCode, 64)
        XCTAssertTrue(refused.stderr.contains("server"))
        XCTAssertEqual(try server.list().first?.level, .server)
    }

    func testUnreadableRoleFailsInsteadOfDefaulting() {
        setting.unreadable = true
        let r = run(["get", "gh"])
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertTrue(r.stderr.contains("unknown host role"))
    }

    // The real file-backed setting: absent ⇒ personal, round-trips, garbage refused.
    func testFileHostRoleSetting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = FileHostRoleSetting(url: dir.appendingPathComponent("mytokens/host-role"))
        XCTAssertEqual(try file.read(), .personal)
        try file.write(.server)
        XCTAssertEqual(try file.read(), .server)
        try Data("laptop\n".utf8).write(to: file.url)
        XCTAssertThrowsError(try file.read())
    }

    func testRoleSelectsTheKeychainLocation() {
        XCTAssertEqual(HostRole.personal.keychain, .iCloud)
        XCTAssertEqual(HostRole.server.keychain, .login)
    }
}
