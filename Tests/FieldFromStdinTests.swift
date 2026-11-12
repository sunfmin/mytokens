import XCTest

// `put --field-from-stdin "<Label>"` stores one secret Field a command pipes in, with no
// popup and no terminal prompt (ADR-0017). Driven through the stdin seam with fakes.
final class FieldFromStdinTests: XCTestCase {
    private var store = InMemorySecretStore()
    private var input = RecordingSecretInput(.cancelled)
    private var setting = InMemoryHostRoleSetting()

    override func setUp() {
        store = InMemorySecretStore()
        input = RecordingSecretInput(.cancelled)
        setting = InMemoryHostRoleSetting()
    }

    private func run(_ argv: [String], stdin: String = "", terminal: Bool = false,
                     prompted: [String: String]? = nil) -> CommandResult {
        let answer: SecretInput = prompted.map { CannedSecretInput(values: $0) } ?? input
        var deps = Dependencies(role: setting, store: { [store] _ in store }, input: { _ in answer },
                                remote: RecordingRemote(), stdin: { Data(stdin.utf8) })
        deps.stdinIsTerminal = { terminal }
        return runCommand(argv, deps)
    }

    private func get(_ service: String, _ field: String) -> String {
        run(["get", service, "--field", field]).stdout
    }

    func testStoresThePipedFieldWithNoPromptAndGetReturnsItExactly() {
        let value = "  p@ss w0rd\twith 'quotes' $HOME \\n  "
        let r = run(["put", "dev", "--description", "Developer ID", "--field-from-stdin", "P12 password"],
                    stdin: value + "\n")
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        XCTAssertEqual(r.stdout, "stored dev/default\n")
        XCTAssertEqual(r.stderr, "")
        XCTAssertTrue(input.prompts.isEmpty)                 // no popup, no terminal prompt
        XCTAssertEqual(get("dev", "P12 password"), value)   // byte for byte, one newline stripped
    }

    func testStripsExactlyOneTrailingNewline() {
        XCTAssertEqual(run(["put", "a", "--field-from-stdin", "X"], stdin: "v\n\n").exitCode, 0)
        XCTAssertEqual(get("a", "X"), "v\n")
        XCTAssertEqual(run(["put", "b", "--field-from-stdin", "X"], stdin: "v").exitCode, 0)
        XCTAssertEqual(get("b", "X"), "v")
        XCTAssertEqual(run(["put", "c", "--field-from-stdin", "X"], stdin: "line1\nline2\r\n").exitCode, 0)
        XCTAssertEqual(get("c", "X"), "line1\nline2\r")
    }

    func testAValueLongerThanATerminalLineIsStoredWhole() {
        let p12 = String(repeating: "MIIQ+wIBAzCCEL8GCSqGSIb3DQEHAaCCELAEghCs", count: 120)   // 4800 bytes
        XCTAssertEqual(run(["put", "dev", "--field-from-stdin", "P12 (base64)"], stdin: p12 + "\n").exitCode, 0)
        XCTAssertEqual(get("dev", "P12 (base64)"), p12)
    }

    func testKeepsTheOtherFieldsAndCombinesWithSetDescriptionAndLevel() {
        XCTAssertEqual(run(["put", "dev", "--description", "Developer ID", "--field-from-stdin", "P12 (base64)"],
                           stdin: "BASE64").exitCode, 0)
        let r = run(["put", "dev", "--level", "server", "--set", "Team=ABC123", "--field-from-stdin", "P12 password"],
                    stdin: "pw\n")
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        XCTAssertEqual(get("dev", "P12 (base64)"), "BASE64")
        XCTAssertEqual(get("dev", "P12 password"), "pw")
        XCTAssertEqual(get("dev", "Team"), "ABC123")
        let record = try! store.list().first { $0.service == "dev" }
        XCTAssertEqual(record?.fields, ["P12 (base64)", "Team", "P12 password"])
        XCTAssertEqual(record?.description, "Developer ID")
        XCTAssertEqual(record?.level, .server)
    }

    func testCombinesWithFieldsInOnePut() {
        let r = run(["put", "aws", "--fields", "Access Key ID", "--field-from-stdin", "Secret Access Key"],
                    stdin: "sshhh", prompted: ["Access Key ID": "AKIA"])
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        XCTAssertEqual(get("aws", "Access Key ID"), "AKIA")
        XCTAssertEqual(get("aws", "Secret Access Key"), "sshhh")
    }

    func testAProfileTakesItLikeFields() {
        XCTAssertEqual(run(["put", "llm", "--kind", "profile", "--set", "API_URL=https://x",
                            "--field-from-stdin", "API_KEY"], stdin: "k-1\n").exitCode, 0)
        XCTAssertEqual(run(["env", "llm"]).stdout, "export API_URL='https://x'\nexport API_KEY='k-1'\n")
        let bad = run(["put", "llm", "--field-from-stdin", "API KEY"], stdin: "k")
        XCTAssertEqual(bad.exitCode, 64)
        XCTAssertTrue(bad.stderr.contains("environment-variable name"), bad.stderr)
    }

    func testRefusedWhenStdinIsATerminal() {
        let r = run(["put", "dev", "--field-from-stdin", "P12 password"], stdin: "typed", terminal: true)
        XCTAssertEqual(r.exitCode, 64)
        XCTAssertTrue(r.stderr.contains("terminal"), r.stderr)
        XCTAssertTrue(r.stderr.contains("--fields"), r.stderr)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(input.prompts.isEmpty)
    }

    func testRefusedWhenStdinIsEmpty() {
        for empty in ["", "\n"] {
            let r = run(["put", "dev", "--field-from-stdin", "P12 password"], stdin: empty)
            XCTAssertEqual(r.exitCode, 64)
            XCTAssertTrue(r.stderr.contains("empty"), r.stderr)
            XCTAssertTrue(r.stderr.contains("--fields"), r.stderr)
        }
        XCTAssertTrue(store.items.isEmpty)
    }

    func testRefusedWithoutALabelOrWithALabelNamedTwice() {
        XCTAssertEqual(run(["put", "dev", "--field-from-stdin"], stdin: "v").exitCode, 64)
        let twice = run(["put", "dev", "--set", "X=a", "--field-from-stdin", "X"], stdin: "v")
        XCTAssertEqual(twice.exitCode, 64)
        XCTAssertTrue(twice.stderr.contains("more than once"), twice.stderr)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testRefusedOnASingleValueSecret() {
        store = InMemorySecretStore()
        try! store.upsert(service: "gh", account: "default", secret: SecretValue(single: "tok"), kind: "static",
                          meta: nil, description: nil, level: .personal, pushed: false)
        let r = run(["put", "gh", "--field-from-stdin", "Token"], stdin: "new")
        XCTAssertNotEqual(r.exitCode, 0)
        XCTAssertEqual(try! store.get(service: "gh", account: "default")?.loneValue, "tok")
    }

    func testTheValueNeverAppearsInOutput() {
        let secret = "do-not-print-me-9f3a"
        for argv in [["put", "dev", "--field-from-stdin", "P"],
                     ["put", "dev", "--kind", "parent", "--field-from-stdin", "P"],
                     ["list"]] {
            let r = run(argv, stdin: secret)
            XCTAssertFalse(r.stdout.contains(secret), "\(argv): \(r.stdout)")
            XCTAssertFalse(r.stderr.contains(secret), "\(argv): \(r.stderr)")
        }
    }

    func testWorksOnAServerAsServerLevel() {
        setting.role = .server
        XCTAssertEqual(run(["put", "dev", "--field-from-stdin", "P"], stdin: "v").exitCode, 0)
        XCTAssertEqual(try! store.list().first { $0.service == "dev" }?.level, .server)
        let personal = run(["put", "dev2", "--level", "personal", "--field-from-stdin", "P"], stdin: "v")
        XCTAssertEqual(personal.exitCode, 64)
    }
}
