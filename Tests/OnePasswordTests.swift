import XCTest

// The 1Password vault target (ADR-0022): `onepassword add|rm|list` and Background Sync make a
// vault hold exactly the `server`-level Secrets. A fake `op` on PATH (a shell script) records
// every call — arguments, the token in its environment, stdin — and answers `item list` from
// a vault the test keeps in step with the calls it replays; no real 1Password is involved.
final class OnePasswordTests: XCTestCase {
    private var dir = ""
    private var laptop = InMemorySecretStore()
    private var vaults = InMemoryServerList()
    private var state = MemoryBackgroundSyncState()
    private var bark = RecordingBarkTransport()
    private var clock = Date(timeIntervalSince1970: 1_794_441_600)
    private var vault: [[String: Any]] = []     // what the fake vault holds: id, title, tags
    private var replayed = 0

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "fake-op-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/bin", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir + "/calls", withIntermediateDirectories: true)
        let script = """
            #!/bin/sh
            d='\(dir)'
            n=$(( $(ls "$d/calls" | grep -c args) + 1 ))
            printf '%s\\n' "$@" > "$d/calls/$n.args"
            printf '%s' "$OP_SERVICE_ACCOUNT_TOKEN" > "$d/calls/$n.token"
            cat > "$d/calls/$n.stdin"
            if [ -f "$d/fail" ]; then cat "$d/fail" >&2; exit 1; fi
            if [ "$1 $2" = "item list" ]; then cat "$d/list.json"; fi

            """
        try script.write(toFile: dir + "/bin/op", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir + "/bin/op")
        laptop = InMemorySecretStore(); vaults = InMemoryServerList(); state = MemoryBackgroundSyncState()
        bark = RecordingBarkTransport(); vault = []; replayed = 0
        try publishVault()
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    private struct Call { var args: [String]; var token: String; var stdin: String }

    private func calls() throws -> [Call] {
        let n = try FileManager.default.contentsOfDirectory(atPath: dir + "/calls").filter { $0.hasSuffix(".args") }.count
        return try (1...max(n, 1)).prefix(n).map { i in
            func read(_ ext: String) throws -> String { try String(contentsOfFile: "\(dir)/calls/\(i).\(ext)", encoding: .utf8) }
            return Call(args: try read("args").split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init),
                        token: try read("token"), stdin: try read("stdin"))
        }
    }

    private func publishVault() throws {
        try JSONSerialization.data(withJSONObject: vault).write(to: URL(fileURLWithPath: dir + "/list.json"))
    }

    /// Writes the calls made since the last replay into the fake vault, as 1Password would.
    private func replay() throws {
        let all = try calls()
        for (i, c) in all.enumerated() where i >= replayed {
            guard c.args.first == "item" else { continue }
            let template = (try? JSONSerialization.jsonObject(with: Data(c.stdin.utf8))) as? [String: Any]
            switch c.args[1] {
            case "create": vault.append(["id": "id\(i + 1)", "title": template?["title"] ?? "", "tags": template?["tags"] ?? []])
            case "edit": vault = vault.map { ($0["id"] as? String) == c.args[2] ? ["id": c.args[2], "title": template?["title"] ?? "", "tags": template?["tags"] ?? []] : $0 }
            case "delete": vault.removeAll { ($0["id"] as? String) == c.args[2] }
            default: break
            }
        }
        replayed = all.count
        try publishVault()
    }

    private func writes() throws -> [Call] { try calls().filter { ["create", "edit", "delete"].contains($0.args[1]) } }

    private var deps: Dependencies {
        var d = Dependencies(store: laptop, input: CannedSecretInput(value: nil))
        d.servers = InMemoryServerList(); d.vaults = vaults; d.syncState = state; d.bark = bark; d.now = { self.clock }
        d.onepassword = OPCommand(path: dir + "/bin:/usr/bin:/bin")
        return d
    }

    private func store(_ s: String, _ a: String = "default", _ v: String = "v", level: Level = .server, description: String? = nil,
                       fields: [(label: String, value: String)]? = nil) throws {
        try laptop.upsert(service: s, account: a, secret: fields.map { SecretValue(fields: $0) } ?? SecretValue(single: v), kind: "static",
                          meta: nil, description: description, level: level, marks: SyncMarks())
    }

    private func putToken() throws { try store(onePasswordTokenService, "default", "ops_TOKEN", level: .personal) }

    private func run(_ argv: [String]) -> CommandResult { runCommand(argv, deps) }

    func testNoTokenSaysWhichPutToRunAndCallsNothing() throws {
        try store("github", "ci", "ghp_x")
        let r = run(["onepassword", "add", "Servers"])
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertTrue(r.stderr.contains("mytokens put 1password-service-account"), r.stderr)
        XCTAssertEqual(try calls().filter { $0.args.first == "item" }.count, 0)
        XCTAssertEqual(try vaults.read(), [])
    }

    func testAddMakesTheVaultHoldTheServerLevelSecretsOneItemEach() throws {
        try putToken()
        try store("github", "ci", "ghp_SECRET", description: "CI token")
        try store("aws", "prod", fields: [("AccessKeyId", "AKIA1"), ("SecretAccessKey", "sk_2")])
        try store("personal-only", "x", "nope", level: .personal)
        let r = run(["onepassword", "add", "Servers"])
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        XCTAssertEqual(r.stdout, "added aws.prod\nadded github.ci\nadded Servers to the vault list\n")
        XCTAssertEqual(try vaults.read(), ["Servers"])
        let creates = try writes()
        XCTAssertEqual(creates.map { $0.args.prefix(2).joined(separator: " ") }, ["item create", "item create"])
        for c in try calls() {
            XCTAssertEqual(c.token, "ops_TOKEN")                                   // in the environment
            XCTAssertFalse(c.args.joined().contains("ops_TOKEN") || c.args.joined().contains("ghp_SECRET"), "\(c.args)")
        }
        let gh = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(creates[1].stdin.utf8)) as? [String: Any])
        XCTAssertEqual(gh["title"] as? String, "github.ci")
        XCTAssertTrue((gh["tags"] as? [String])?.contains("mytokens") == true)
        let fields = try XCTUnwrap(gh["fields"] as? [[String: Any]])
        XCTAssertTrue(fields.contains { $0["type"] as? String == "CONCEALED" && $0["value"] as? String == "ghp_SECRET" })
        XCTAssertTrue(fields.contains { $0["purpose"] as? String == "NOTES" && $0["value"] as? String == "CI token" })
        let aws = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(creates[0].stdin.utf8)) as? [String: Any])
        let labels = (aws["fields"] as? [[String: Any]])?.compactMap { $0["label"] as? String }
        XCTAssertEqual(labels, ["AccessKeyId", "SecretAccessKey"])
        XCTAssertFalse(creates.contains { $0.stdin.contains("nope") || $0.stdin.contains("ops_TOKEN") })
    }

    private func storeList(_ s: String, _ a: String, _ json: String) throws {
        try laptop.upsert(service: s, account: a,
                          secret: SecretValue(fields: [(label: "Hosts", value: try XCTUnwrap(ListValue.canonical(json)))], lists: ["Hosts"]),
                          kind: "static", meta: nil, description: nil, level: .server, marks: SyncMarks())
    }

    private func template(_ c: Call) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(c.stdin.utf8)) as? [String: Any])
    }

    func testAListFieldIsOneSectionPerRecordAndRecordCountChangesAddOrRemoveSections() throws {
        try putToken()
        try storeList("db", "prod", #"[{"user":"app","host":"db1","password":"p1"},{"host":"db2","user":"app","password":"p2"}]"#)
        XCTAssertEqual(run(["onepassword", "add", "Servers"]).exitCode, 0)
        try replay()
        let t = try template(try XCTUnwrap(try writes().first))
        let sections = try XCTUnwrap(t["sections"] as? [[String: Any]])
        XCTAssertEqual(sections.map { $0["label"] as? String }, ["Hosts [1]", "Hosts [2]"])
        let fields = try XCTUnwrap(t["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.map { $0["label"] as? String }, ["host", "password", "user", "host", "password", "user"])  // key order
        XCTAssertTrue(fields.allSatisfy { $0["type"] as? String == "CONCEALED" })
        let second = fields.filter { ($0["section"] as? [String: Any])?["label"] as? String == "Hosts [2]" }
        XCTAssertEqual(second.compactMap { $0["value"] as? String }, ["db2", "p2", "app"])
        // unchanged: no write
        let mark = try writes().count
        XCTAssertEqual(try? syncVault("Servers", store: laptop, cli: deps.onepassword).get(), ["no changes"])
        XCTAssertEqual(try writes().count, mark)
        // one record fewer: one section fewer; one more: one more
        try storeList("db", "prod", #"[{"host":"db1","password":"p1","user":"app"}]"#)
        XCTAssertEqual(try? syncVault("Servers", store: laptop, cli: deps.onepassword).get(), ["updated db.prod"])
        try replay()
        let fewer = try template(try XCTUnwrap(try writes().last))
        XCTAssertEqual((fewer["sections"] as? [[String: Any]])?.count, 1)
        try storeList("db", "prod", #"[{"a":"1"},{"a":"2"},{"a":"3"}]"#)
        XCTAssertEqual(try? syncVault("Servers", store: laptop, cli: deps.onepassword).get(), ["updated db.prod"])
        let more = try template(try XCTUnwrap(try writes().last))
        XCTAssertEqual((more["sections"] as? [[String: Any]])?.map { $0["label"] as? String }, ["Hosts [1]", "Hosts [2]", "Hosts [3]"])
    }

    func testASecondSyncWithNothingChangedMakesNoWrites() throws {
        try putToken()
        try store("github", "ci", "ghp_x")
        XCTAssertEqual(run(["onepassword", "add", "Servers"]).exitCode, 0)
        try replay()
        let before = try writes().count
        let r = syncVault("Servers", store: laptop, cli: deps.onepassword)
        XCTAssertEqual(try? r.get(), ["no changes"])
        XCTAssertEqual(try writes().count, before)
    }

    func testAChangedValueUpdatesAndAGoneOrLoweredSecretIsArchivedAndForeignItemsAreNeverTouched() throws {
        try putToken()
        try store("github", "ci", "one")
        try store("old", "x", "gone")
        XCTAssertEqual(run(["onepassword", "add", "Servers"]).exitCode, 0)
        try replay()
        vault.append(["id": "foreign", "title": "my bank", "tags": ["personal"]])
        try publishVault()
        let mark = try writes().count
        try store("github", "ci", "two")
        try store("old", "x", "gone", level: .personal)        // lowered
        let r = syncVault("Servers", store: laptop, cli: deps.onepassword)
        XCTAssertEqual(try? r.get(), ["updated github.ci", "removed old.x"])
        let after = Array(try writes().dropFirst(mark))
        XCTAssertEqual(after.count, 2)
        XCTAssertTrue(after.contains { $0.args.prefix(3).joined(separator: " ").hasPrefix("item edit") && $0.stdin.contains("two") })
        XCTAssertTrue(after.contains { $0.args.contains("delete") && $0.args.contains("--archive") })
        XCTAssertFalse(after.contains { $0.args.contains("foreign") })
    }

    func testTheTokenSecretIsNeverExportedEvenAtServerLevel() throws {
        try store(onePasswordTokenService, "default", "ops_TOKEN", level: .server)
        try store("github", "ci", "x")
        XCTAssertEqual(run(["onepassword", "add", "Servers"]).exitCode, 0)
        XCTAssertFalse(try writes().contains { $0.stdin.contains("ops_TOKEN") })
    }

    func testAFailingAddLeavesTheVaultOffTheListAndRmEmptiesThenForgets() throws {
        try putToken()
        try store("github", "ci", "x")
        try "(403) Forbidden\n".write(toFile: dir + "/fail", atomically: true, encoding: .utf8)
        let bad = run(["onepassword", "add", "Servers"])
        XCTAssertEqual(bad.exitCode, 1)
        XCTAssertTrue(bad.stderr.contains("failed to list the vault") && bad.stderr.contains("Forbidden"), bad.stderr)
        XCTAssertEqual(try vaults.read(), [])
        try FileManager.default.removeItem(atPath: dir + "/fail")
        XCTAssertEqual(run(["onepassword", "add", "Servers"]).exitCode, 0)
        try replay()
        let r = run(["onepassword", "rm", "Servers"])
        XCTAssertEqual(r.stdout, "removed github.ci\nremoved Servers from the vault list\n")
        XCTAssertEqual(try vaults.read(), [])
        XCTAssertEqual(run(["onepassword", "rm", "Servers"]).exitCode, 1)
    }

    func testBackgroundSyncIncludesTheVaultAndListShowsItsStatusAndFailure() throws {
        try putToken()
        try store("github", "ci", "x")
        try vaults.write(["Servers"])
        var r = run(["server", "sync"])
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        XCTAssertTrue(r.stdout.contains("1Password vault Servers: added github.ci"), r.stdout)
        XCTAssertEqual(run(["onepassword", "list"]).stdout, "Servers\tlast synced 2026-11-12 08:00\n")
        // It fails; after 24 hours it is told through Bark, as a host would be.
        try "boom\n".write(toFile: dir + "/fail", atomically: true, encoding: .utf8)
        clock += 60
        r = run(["server", "sync"])
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertTrue(run(["onepassword", "list"]).stdout.contains("failed to list the vault"))
        try store("bark", "default", "https://bark.example/KEY", level: .personal)
        clock += 25 * 3600
        _ = run(["server", "sync"])
        XCTAssertEqual(bark.pushes.count, 1)
        XCTAssertTrue(bark.pushes[0].title.contains("1Password vault Servers"), bark.pushes[0].title)
    }

    func testNothingIsAdoptedFromAVaultAndTheCommandIsRefusedOnAServer() throws {
        let server = Dependencies(role: InMemoryHostRoleSetting(.server), store: { _ in self.laptop },
                                  input: { _ in CannedSecretInput(value: nil) }, remote: RecordingRemote(), stdin: { Data() })
        XCTAssertEqual(runCommand(["onepassword", "add", "V"], server).exitCode, 64)
        XCTAssertEqual(runCommand(["put", vaultListService], deps).exitCode, 64)
        try putToken()
        vault = [["id": "x", "title": "elsewhere.item", "tags": ["mytokens", "mytokens-digest-abc"]]]
        try publishVault()
        _ = run(["onepassword", "add", "V"])
        XCTAssertNil(try laptop.get(service: "elsewhere", account: "item"))
    }

    func testAHandCopiedItemIsTakenOverInPlaceAndAnUnmatchedOneSurvivesTwoSyncs() throws {
        try putToken()
        try store("bark", "default", "https://bark.example/KEY")
        vault = [["id": "hand1", "title": "bark", "tags": ["mytokens"], "category": "SECURE_NOTE"],
                 ["id": "hand2", "title": "unrelated", "tags": ["mytokens"], "category": "SECURE_NOTE"]]
        try publishVault()
        XCTAssertEqual(try? syncVault("devbox", store: laptop, cli: deps.onepassword).get(), ["took over bark"])
        let w = try writes()
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(Array(w[0].args.prefix(3)), ["item", "edit", "hand1"])
        let t = try template(w[0])
        XCTAssertEqual(t["title"] as? String, "bark")
        XCTAssertNil(t["category"])                                  // its own category is kept
        XCTAssertTrue((t["tags"] as? [String])?.contains { $0.hasPrefix("mytokens-digest-") } == true)
        try replay()
        XCTAssertEqual(try? syncVault("devbox", store: laptop, cli: deps.onepassword).get(), ["no changes"])
        XCTAssertEqual(try writes().count, 1)
        XCTAssertFalse(try writes().contains { $0.args.contains("hand2") })
        try vaults.write(["devbox"])
        XCTAssertTrue(run(["onepassword", "list"]).stdout.contains("1 hand-made item tagged mytokens left alone"))
    }

    func testANonDefaultAccountIsTitledServiceDotAccountAndNeverHasASlash() throws {
        try putToken()
        try store("github", "ci", "x")
        try store("bark", "default", "y")
        XCTAssertEqual(try? syncVault("V", store: laptop, cli: deps.onepassword).get(), ["added bark", "added github.ci"])
        XCTAssertFalse(try writes().contains { (try? template($0))?["title"].map { "\($0)".contains("/") } ?? true })
    }

    func testATitleCollisionFailsNamingBothAndWritesNothing() throws {
        try putToken()
        try store("github", "ci", "x")
        try store("github.ci", "default", "y")
        let r = syncVault("V", store: laptop, cli: deps.onepassword)
        guard case .failure(let f) = r else { return XCTFail("expected failure") }
        XCTAssertTrue(f.why.contains("github/ci") && f.why.contains("github.ci/default"), f.why)
        XCTAssertEqual(try writes().count, 0)
    }
}
