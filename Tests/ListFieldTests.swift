import XCTest

// A labelled Field may hold a list of records (ADR-0019): piped in with
// `put --field-from-stdin "<Label>" --list`, kept as a list in the keychain comment's field
// schema, printed as JSON by `get`, counted by `list`, refused by every one-string path and by
// a Profile, and carried by Sync both ways unchanged.
final class ListFieldTests: XCTestCase {
    private var store = InMemorySecretStore()
    private var input = RecordingSecretInput(.cancelled)
    private var setting = InMemoryHostRoleSetting()

    private let hosts = #"[{"host":"db1","user":"app","password":"p/1 'x'"},{"host":"db2","user":"app","password":"p2"}]"#
    /// `hosts` as `get` prints it: compact, records in order, keys sorted within each.
    private let hostsCanonical = #"[{"host":"db1","password":"p/1 'x'","user":"app"},{"host":"db2","password":"p2","user":"app"}]"#

    override func setUp() {
        store = InMemorySecretStore()
        input = RecordingSecretInput(.cancelled)
        setting = InMemoryHostRoleSetting()
    }

    private func run(_ argv: [String], stdin: String = "", prompted: [String: String]? = nil) -> CommandResult {
        let answer: SecretInput = prompted.map { CannedSecretInput(values: $0) } ?? input
        return runCommand(argv, Dependencies(role: setting, store: { [store] _ in store }, input: { _ in answer },
                                             remote: RecordingRemote(), stdin: { Data(stdin.utf8) }))
    }

    private func putHosts(_ service: String = "db", _ extra: [String] = []) -> CommandResult {
        run(["put", service, "--field-from-stdin", "Hosts", "--list"] + extra, stdin: hosts + "\n")
    }

    func testPutStoresAListAndGetFieldPrintsItAsCompactJSON() {
        let r = putHosts()
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        XCTAssertEqual(r.stdout, "stored db/default\n")
        XCTAssertTrue(input.prompts.isEmpty)
        XCTAssertEqual(run(["get", "db", "--field", "Hosts"]).stdout, hostsCanonical)
        XCTAssertTrue(try store.get(service: "db", account: "default")!.isList("Hosts"))
    }

    func testGetJSONPutsTheArrayItselfUnderFields() throws {
        XCTAssertEqual(run(["put", "db", "--set", "Region=eu"]).exitCode, 0)
        XCTAssertEqual(putHosts().exitCode, 0)
        let out = run(["get", "db", "--json"]).stdout
        let obj = try XCTUnwrap(JSONUtil.parse(out) as? [String: Any])
        let fields = try XCTUnwrap(obj["fields"] as? [String: Any])
        XCTAssertEqual(fields["Region"] as? String, "eu")
        let list = try XCTUnwrap(fields["Hosts"] as? [[String: String]], "a list, not a JSON string: \(out)")
        XCTAssertEqual(list.map { $0["host"] }, ["db1", "db2"])
        XCTAssertEqual(list[0]["password"], "p/1 'x'")
    }

    func testListShowsTheLabelAsAListWithItsCountAndNoValues() {
        XCTAssertEqual(run(["put", "db", "--set", "Region=eu"]).exitCode, 0)
        XCTAssertEqual(putHosts().exitCode, 0)
        XCTAssertEqual(run(["put", "one", "--field-from-stdin", "Hosts", "--list"], stdin: #"[{"a":"b"}]"#).exitCode, 0)
        let out = run(["list"]).stdout
        XCTAssertTrue(out.contains("db/default\tstatic\tpersonal  fields: Region, Hosts (list, 2 records)"), out)
        XCTAssertTrue(out.contains("fields: Hosts (list, 1 record)"), out)
        for value in ["db1", "p2", "eu"] { XCTAssertFalse(out.contains(value), out) }
    }

    func testAnythingButAListOfFlatStringRecordsIsRefusedBeforeTheStoreIsTouched() {
        let bad = [#"{"host":"db1"}"#, #""text""#, "not json", "[]", #"["db1"]"#, "[{}]",
                   #"[{"port":5432}]"#, #"[{"ok":true}]"#, #"[{"nested":{"a":"b"}}]"#, #"[{"list":["a"]}]"#,
                   #"[{"":"empty key"}]"#, #"[{"a":null}]"#]
        for stdin in bad {
            let r = run(["put", "db", "--field-from-stdin", "Hosts", "--list"], stdin: stdin)
            XCTAssertEqual(r.exitCode, 64, stdin)
            XCTAssertTrue(r.stderr.contains("JSON array of flat records with string values"), "\(stdin): \(r.stderr)")
            XCTAssertTrue(r.stderr.contains("nothing stored"), r.stderr)
        }
        XCTAssertTrue(store.items.isEmpty)
        let noStdin = run(["put", "db", "--list", "--set", "A=b"])
        XCTAssertEqual(noStdin.exitCode, 64)
        XCTAssertTrue(noStdin.stderr.contains("--field-from-stdin"), noStdin.stderr)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testAListKeepsTheOtherFieldsAndCanBeReplaced() {
        XCTAssertEqual(run(["put", "db", "--set", "Region=eu"]).exitCode, 0)
        XCTAssertEqual(putHosts().exitCode, 0)
        XCTAssertEqual(run(["put", "db", "--field-from-stdin", "Hosts", "--list"], stdin: #"[{"host":"db3"}]"#).exitCode, 0)
        XCTAssertEqual(run(["get", "db", "--field", "Hosts"]).stdout, #"[{"host":"db3"}]"#)
        XCTAssertEqual(run(["get", "db", "--field", "Region"]).stdout, "eu")
        XCTAssertEqual(run(["put", "db", "--set", "Region=us"]).exitCode, 0)   // another Field: the list stays
        XCTAssertTrue(try store.get(service: "db", account: "default")!.isList("Hosts"))
    }

    func testEveryOneStringPathRefusesAListFieldAndNamesTheStdinPath() {
        XCTAssertEqual(putHosts().exitCode, 0)
        let attempts: [([String], String)] = [
            (["put", "db", "--fields", "Hosts"], ""),                      // terminal, popup, one-time link
            (["put", "db", "--set", "Hosts=db1"], ""),
            (["put", "db", "--field-from-stdin", "Hosts"], "db1"),          // stdin, but as text
        ]
        for (argv, stdin) in attempts {
            let r = run(argv, stdin: stdin, prompted: ["Hosts": "typed"])
            XCTAssertEqual(r.exitCode, 64, "\(argv)")
            XCTAssertTrue(r.stderr.contains("is a list"), r.stderr)
            XCTAssertTrue(r.stderr.contains("--field-from-stdin Hosts --list"), r.stderr)
        }
        XCTAssertTrue(input.prompts.isEmpty)
        XCTAssertEqual(run(["get", "db", "--field", "Hosts"]).stdout, hostsCanonical)
    }

    func testAProfileRefusesAListField() {
        XCTAssertEqual(run(["put", "llm", "--kind", "profile", "--set", "API_URL=https://x"]).exitCode, 0)
        let r = run(["put", "llm", "--field-from-stdin", "HOSTS", "--list"], stdin: hosts)
        XCTAssertEqual(r.exitCode, 64)
        XCTAssertTrue(r.stderr.contains("environment variable"), r.stderr)
        let fresh = run(["put", "p2", "--kind", "profile", "--field-from-stdin", "HOSTS", "--list"], stdin: hosts)
        XCTAssertEqual(fresh.exitCode, 64)
        XCTAssertNil(try store.get(service: "p2", account: "default"))
        XCTAssertEqual(run(["env", "llm"]).stdout, "export API_URL='https://x'\n")

        // `env` refuses one that got there anyway (an item written by another build).
        try! store.upsert(service: "bad", account: "default",
                          secret: SecretValue(fields: [(label: "HOSTS", value: hostsCanonical)], lists: ["HOSTS"]),
                          kind: "profile", meta: nil, description: nil, level: .personal, pushed: false)
        let env = run(["env", "bad"])
        XCTAssertEqual(env.exitCode, 1)
        XCTAssertTrue(env.stderr.contains("is a list"), env.stderr)
        XCTAssertEqual(env.stdout, "")
    }

    /// The real store: the list kind lives in the comment's field schema, and the list
    /// reads back as a list with its count, not as a text Field.
    func testTheKeychainCommentRecordsTheListKind() throws {
        let keychain = InMemoryKeychain()
        let real = KeychainSecretStore(location: .iCloud, keychain: keychain)
        try real.upsert(service: "db", account: "default",
                        secret: SecretValue(fields: [(label: "Region", value: "eu"), (label: "Hosts", value: hostsCanonical)],
                                            lists: ["Hosts"]),
                        kind: "static", meta: nil, description: nil, level: .server, pushed: false)
        let comment = try XCTUnwrap(keychain.items.first?[kSecAttrComment as String] as? String)
        XCTAssertEqual(CommentCodec.decode(comment).fields, ["Region", "Hosts"])
        XCTAssertEqual(CommentCodec.decode(comment).lists, ["Hosts": 2])
        let back = try XCTUnwrap(real.get(service: "db", account: "default"))
        XCTAssertEqual(back.lists, ["Hosts"])
        XCTAssertEqual(back.value(forField: "Hosts"), hostsCanonical)
        XCTAssertEqual(back.value(forField: "Region"), "eu")
        XCTAssertEqual(try real.list().first?.lists, ["Hosts": 2])
        XCTAssertEqual(try real.list().first?.fields, ["Region", "Hosts"])
    }

    // MARK: Sync

    private var server = InMemorySecretStore()

    private func on(_ role: HostRole, _ target: InMemorySecretStore, _ argv: [String], stdin: Data = Data(),
                    remote: Remote = RecordingRemote()) -> CommandResult {
        runCommand(argv, Dependencies(role: InMemoryHostRoleSetting(role), store: { _ in target },
                                      input: { _ in CannedSecretInput(values: nil) }, remote: remote, stdin: { stdin }))
    }

    private func syncRemote() -> Remote {
        RecordingRemote { [unowned self] command, payload in
            switch command {
            case remoteExportCommand: return self.on(.server, self.server, ["get", "--unpushed"])
            case remotePutCommand: return self.on(.server, self.server, ["put", "--stdin"], stdin: payload)
            default: return CommandResult(stdout: "", stderr: "unexpected \(command)\n", exitCode: 127)
            }
        }
    }

    func testSyncCarriesAListToTheServerAndAdoptsOneBackUnchanged() {
        server = InMemorySecretStore()
        let laptop = store
        // Pushed: entered on the personal Mac, server-level.
        XCTAssertEqual(on(.personal, laptop, ["put", "db", "--level", "server", "--field-from-stdin", "Hosts", "--list"],
                          stdin: Data(hosts.utf8)).exitCode, 0)
        // Adopted: entered on the Server.
        XCTAssertEqual(on(.server, server, ["put", "ci", "--field-from-stdin", "Runners", "--list"],
                          stdin: Data(#"[{"name":"r1","token":"t1"}]"#.utf8)).exitCode, 0)

        let remote = syncRemote()
        let r = on(.personal, laptop, ["sync", "mini"], remote: remote)
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        XCTAssertEqual(r.stdout, "adopted ci/default\nadded db/default\n")

        XCTAssertEqual(on(.server, server, ["get", "db", "--field", "Hosts"]).stdout, hostsCanonical)
        XCTAssertTrue(try server.get(service: "db", account: "default")!.isList("Hosts"))
        XCTAssertEqual(on(.personal, laptop, ["get", "ci", "--field", "Runners"]).stdout, #"[{"name":"r1","token":"t1"}]"#)
        XCTAssertTrue(try laptop.get(service: "ci", account: "default")!.isList("Runners"))
        XCTAssertTrue(on(.personal, laptop, ["list"]).stdout.contains("Runners (list, 1 record)"))

        // Round trip: nothing differs, so a second sync changes nothing.
        XCTAssertEqual(on(.personal, laptop, ["sync", "mini"], remote: remote).stdout, "no changes\n")
    }
}
