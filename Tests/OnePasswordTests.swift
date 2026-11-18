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
    private var versions: [String: Int] = [:]

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "fake-op-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/bin", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir + "/calls", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir + "/items", withIntermediateDirectories: true)
        let script = """
            #!/bin/sh
            d='\(dir)'
            n=$(( $(ls "$d/calls" | grep -c args) + 1 ))
            printf '%s\\n' "$@" > "$d/calls/$n.args"
            printf '%s' "$OP_SERVICE_ACCOUNT_TOKEN" > "$d/calls/$n.token"
            cat > "$d/calls/$n.stdin"
            # real op 2.42 refuses --template together with a piped stdin
            if [ "$1" = item ] && { [ "$2" = create ] || [ "$2" = edit ]; } && [ ! -t 0 ]; then
              for a in "$@"; do
                if [ "$a" = --template ]; then
                  echo "[ERROR] unable to process line 1: cannot $2 an item from template and stdin at the same time" >&2; exit 1
                fi
              done
            fi
            if [ -f "$d/fail" ]; then cat "$d/fail" >&2; exit 1; fi
            if [ "$1 $2" = "item list" ]; then cat "$d/list.json"; fi
            if [ "$1 $2" = "item get" ]; then cat "$d/items/$3.json" || exit 1; fi

            """
        try script.write(toFile: dir + "/bin/op", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir + "/bin/op")
        laptop = InMemorySecretStore(); vaults = InMemoryServerList(); state = MemoryBackgroundSyncState()
        bark = RecordingBarkTransport(); vault = []; replayed = 0; versions = [:]
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

    /// Writes the calls made since the last replay into the fake vault, as 1Password would: the item
    /// is what the template said, and every create or edit gives it a new version.
    private func replay() throws {
        let all = try calls()
        for (i, c) in all.enumerated() where i >= replayed {
            guard c.args.first == "item" else { continue }
            let template = (try? JSONSerialization.jsonObject(with: Data(c.stdin.utf8))) as? [String: Any]
            func entry(_ id: String) -> [String: Any] {
                versions[id, default: 0] += 1
                try? c.stdin.write(toFile: "\(dir)/items/\(id).json", atomically: true, encoding: .utf8)
                var e: [String: Any] = ["id": id, "title": template?["title"] ?? "", "tags": template?["tags"] ?? [], "version": versions[id]!]
                if let old = vault.first(where: { ($0["id"] as? String) == id }), let cat = old["category"] { e["category"] = cat }
                return e
            }
            switch c.args[1] {
            case "create": vault.append(entry("id\(i + 1)"))
            case "edit": vault = vault.map { ($0["id"] as? String) == c.args[2] ? entry(c.args[2]) : $0 }
            case "delete": vault.removeAll { ($0["id"] as? String) == c.args[2] }
            default: break
            }
        }
        replayed = all.count
        try publishVault()
    }

    /// An item someone made in 1Password: what `op item get` answers, and its row in `op item list`.
    private func handMade(_ id: String, _ title: String, category: String = "API_CREDENTIAL", tags: [String] = [], fields: [[String: Any]],
                          files: [[String: Any]]? = nil) throws {
        var item: [String: Any] = ["id": id, "title": title, "category": category, "fields": fields]
        if let files { item["files"] = files }
        try JSONSerialization.data(withJSONObject: item).write(to: URL(fileURLWithPath: "\(dir)/items/\(id).json"))
        vault.removeAll { ($0["id"] as? String) == id }
        versions[id, default: 0] += 1
        vault.append(["id": id, "title": title, "category": category, "tags": tags, "version": versions[id]!])
        try publishVault()
    }

    private func gets() throws -> [Call] { try calls().filter { $0.args.prefix(2) == ["item", "get"] } }

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
        XCTAssertEqual(gh["category"] as? String, "SECURE_NOTE")
        XCTAssertEqual(fields.filter { $0["purpose"] as? String == "NOTES" }.map { $0["value"] as? String }, ["CI token"])  // exactly the Description
        let aws = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(creates[0].stdin.utf8)) as? [String: Any])
        let labels = (aws["fields"] as? [[String: Any]])?.filter { $0["section"] == nil }.compactMap { $0["label"] as? String }
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
        func recordSections(_ t: [String: Any]) -> [[String: Any]] {      // the sections but the metadata one
            (t["sections"] as? [[String: Any]] ?? []).filter { $0["label"] as? String != "mytokens" }
        }
        let sections = recordSections(t)
        XCTAssertEqual(sections.map { $0["label"] as? String }, ["Hosts [1]", "Hosts [2]"])
        let fields = try XCTUnwrap(t["fields"] as? [[String: Any]]).filter { ($0["section"] as? [String: Any])?["label"] as? String != "mytokens" }
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
        XCTAssertEqual(recordSections(fewer).count, 1)
        try storeList("db", "prod", #"[{"a":"1"},{"a":"2"},{"a":"3"}]"#)
        XCTAssertEqual(try? syncVault("Servers", store: laptop, cli: deps.onepassword).get(), ["updated db.prod"])
        let more = try template(try XCTUnwrap(try writes().last))
        XCTAssertEqual(recordSections(more).map { $0["label"] as? String }, ["Hosts [1]", "Hosts [2]", "Hosts [3]"])
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
        try handMade("foreign", "my bank", fields: [["id": "f1", "label": "pin", "value": "1234"]], files: [["id": "x"]])
        let mark = try writes().count
        try store("github", "ci", "two")
        try store("old", "x", "gone", level: .personal)        // lowered
        let r = syncVault("Servers", store: laptop, cli: deps.onepassword)
        XCTAssertEqual(try? r.get(), ["updated github.ci", "removed old.x", "not adopted my bank: it holds a file"])
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

    func testTheCommandIsRefusedOnAServerAndTheVaultListIsReserved() throws {
        let server = Dependencies(role: InMemoryHostRoleSetting(.server), store: { _ in self.laptop },
                                  input: { _ in CannedSecretInput(value: nil) }, remote: RecordingRemote(), stdin: { Data() })
        XCTAssertEqual(runCommand(["onepassword", "add", "V"], server).exitCode, 64)
        XCTAssertEqual(runCommand(["put", vaultListService], deps).exitCode, 64)
    }

    func testAHandCopiedItemIsTakenOverInPlaceAndAnUnmatchedOneSurvivesTwoSyncs() throws {
        try putToken()
        try store("bark", "default", "https://bark.example/KEY")
        vault = [["id": "hand1", "title": "bark", "tags": ["mytokens"], "category": "SECURE_NOTE"]]
        try handMade("hand2", "unrelated", category: "SECURE_NOTE", tags: ["mytokens"], fields: [])      // holds no values
        try publishVault()
        XCTAssertEqual(try? syncVault("devbox", store: laptop, cli: deps.onepassword).get(), ["took over bark", "not adopted unrelated: it holds no values"])
        let w = try writes()
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(Array(w[0].args.prefix(3)), ["item", "edit", "hand1"])
        let t = try template(w[0])
        XCTAssertEqual(t["title"] as? String, "bark")
        XCTAssertNil(t["category"])                                  // its own category is kept
        XCTAssertTrue((t["tags"] as? [String])?.contains { $0.hasPrefix("mytokens-digest-") } == true)
        try replay()
        XCTAssertEqual(try? syncVault("devbox", store: laptop, cli: deps.onepassword).get(), ["not adopted unrelated: it holds no values"])
        XCTAssertEqual(try writes().count, 1)
        XCTAssertFalse(try writes().contains { $0.args.contains("hand2") })
        try vaults.write(["devbox"])
        _ = run(["server", "sync"])
        XCTAssertTrue(run(["onepassword", "list"]).stdout.contains("not adopted unrelated: it holds no values"))
    }

    func testAnItemWrittenInTheOldFormatCountsAsChangedAndIsRewritten() throws {
        try putToken()
        try store("github", "ci", "x")
        // The digest the old format gave: title, notes, [label, value] pairs.
        vault = [["id": "old1", "title": "github.ci", "tags": ["mytokens", "mytokens-digest-0123456789abcdef0123456789abcdef"], "version": 1]]
        let same = VaultItem(service: "github", account: "ci", kind: "static", meta: nil, description: nil, level: .server,
                             secret: SecretValue(single: "x"))
        try same.template().write(to: URL(fileURLWithPath: dir + "/items/old1.json"))
        try publishVault()
        XCTAssertEqual(try? syncVault("V", store: laptop, cli: deps.onepassword).get(), ["updated github.ci"])
        try replay()
        XCTAssertEqual(try? syncVault("V", store: laptop, cli: deps.onepassword).get(), ["no changes"])
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

    // MARK: two-way (mytokens#13)

    private func sec(_ s: String, _ a: String = "default") throws -> (SecretRecord, SecretValue)? {
        guard let r = try laptop.list().first(where: { $0.service == s && $0.account == a }),
              let v = try laptop.get(service: s, account: a) else { return nil }
        return (r, v)
    }
    private func labels(_ v: SecretValue) -> [String] { v.fields.map { "\($0.label)=\($0.value)" } }

    func testAHandMadeLoginIsAdoptedWholeAndRewrittenInMytokensFormatKeepingItsBuiltInIds() throws {
        try putToken()
        try handMade("h1", "stripe", category: "LOGIN", fields: [
            ["id": "username", "label": "username", "purpose": "USERNAME", "type": "STRING", "value": "me"],
            ["id": "password", "label": "password", "purpose": "PASSWORD", "type": "CONCEALED", "value": "pw"],
            ["id": "otp1", "label": "one-time password", "type": "OTP", "value": NSNull()],            // built-in, empty: skipped
            ["id": "notesPlain", "label": "notesPlain", "purpose": "NOTES", "type": "STRING", "value": "the live key"],
            ["id": "k", "label": "Api Key", "type": "CONCEALED", "value": "sk_live", "section": ["id": "Section_x", "label": "Keys"]]])
        XCTAssertEqual(try? syncVault("V", store: laptop, cli: deps.onepassword, now: clock).get(), ["adopted stripe"])
        let (r, v) = try XCTUnwrap(try sec("stripe"))
        XCTAssertEqual(r.level, .server)
        XCTAssertEqual(r.origin, "1password:V")
        XCTAssertEqual(r.description, "adopted from 1Password vault V on 2026-11-12\nthe live key")
        XCTAssertEqual(labels(v), ["username=me", "password=pw", "Api Key=sk_live"])
        let w = try XCTUnwrap(try writes().first)
        XCTAssertEqual(Array(w.args.prefix(5)), ["item", "edit", "h1", "--vault", "V"])
        let t = try template(w)
        XCTAssertNil(t["category"])
        let fields = try XCTUnwrap(t["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.filter { $0["id"] as? String == "password" }.count, 1)
        XCTAssertTrue(fields.contains { $0["id"] as? String == "username" && $0["purpose"] as? String == "USERNAME" })
        XCTAssertTrue((t["tags"] as? [String])?.contains { $0.hasPrefix("mytokens-digest-") } == true)
        // from then on it is the sync's own: a second sync changes nothing
        try replay()
        XCTAssertEqual(try? syncVault("V", store: laptop, cli: deps.onepassword, now: clock).get(), ["no changes"])
        XCTAssertEqual(try writes().count, 1)
    }

    func testTheTitleRuleListsAndUnmappableItemsAreReportedByNameAndReason() throws {
        try putToken()
        try handMade("a", "ci.prod", fields: [["id": "1", "label": "token", "value": "t"]])
        try handMade("b", "hosts", fields: [
            ["id": "1", "label": "host", "value": "h1", "section": ["id": "s1", "label": "Hosts [1]"]],
            ["id": "2", "label": "host", "value": "h2", "section": ["id": "s2", "label": "Hosts [2]"]]])
        try handMade("c", "twice", fields: [["id": "1", "label": "key", "value": "1"], ["id": "2", "label": "key", "value": "2"]])
        try handMade("d", "clash", fields: [["id": "1", "label": "x", "value": "1"],
                                             ["id": "2", "label": "x", "value": "2", "section": ["id": "s", "label": "More"]]])
        try handMade("e", "doc", category: "DOCUMENT", fields: [["id": "1", "label": "x", "value": "1"]])
        let r = try XCTUnwrap(try? syncVault("V", store: laptop, cli: deps.onepassword, now: clock).get())
        XCTAssertEqual(r, ["adopted ci.prod", "not adopted clash: two fields labelled \"x\"", "not adopted doc: it holds a file",
                           "adopted hosts", "not adopted twice: two fields labelled \"key\""])
        let (_, a) = try XCTUnwrap(try sec("ci", "prod"))
        XCTAssertEqual(labels(a), ["token=t"])
        let (_, h) = try XCTUnwrap(try sec("hosts"))
        XCTAssertTrue(h.isList("host") == false && h.isList("Hosts"))
        XCTAssertEqual(h.fields.first?.value, #"[{"host":"h1"},{"host":"h2"}]"#)
        XCTAssertNil(try sec("twice"))
        try vaults.write(["V"])
        _ = run(["server", "sync"])
        let list = run(["onepassword", "list"]).stdout
        XCTAssertTrue(list.contains("not adopted twice: two fields labelled \"key\"") && list.contains("not adopted doc: it holds a file"), list)
    }

    /// A vault that has adopted `stripe` (value `v1`), the memory of it, and the writes counted so far.
    private func adoptedStripe() throws -> VaultMemoryRef {
        try putToken()
        try handMade("h1", "stripe", fields: [["id": "1", "label": "key", "value": "v1"]])
        let memory = VaultMemoryRef()
        XCTAssertEqual(try? syncVault("V", store: laptop, cli: deps.onepassword, now: clock, memory: memory).get(), ["adopted stripe"])
        try replay()
        return memory
    }

    private func editInVault(_ id: String, _ value: String) throws {
        let json = try String(contentsOfFile: "\(dir)/items/\(id).json", encoding: .utf8)
        try json.replacingOccurrences(of: "\"v1\"", with: "\"\(value)\"").write(toFile: "\(dir)/items/\(id).json", atomically: true, encoding: .utf8)
        versions[id, default: 0] += 1
        vault = vault.map { ($0["id"] as? String) == id ? $0.merging(["version": versions[id]!]) { $1 } : $0 }
        try publishVault()
    }

    func testAChangeMadeInThePasswordManagerFlowsBackAndAnUnchangedVersionIsNotRead() throws {
        let memory = try adoptedStripe()
        // the version op listed after our write is learned by the next sync, which reads once ...
        XCTAssertEqual(try? syncVault("V", store: laptop, cli: deps.onepassword, now: clock, memory: memory).get(), ["no changes"])
        let reads = try gets().count
        // ... and from then on a sync that sees the same version reads nothing
        XCTAssertEqual(try? syncVault("V", store: laptop, cli: deps.onepassword, now: clock, memory: memory).get(), ["no changes"])
        XCTAssertEqual(try gets().count, reads)
        let writesBefore = try writes().count
        try editInVault("h1", "v2")
        XCTAssertEqual(try? syncVault("V", store: laptop, cli: deps.onepassword, now: clock, memory: memory).get(),
                       ["adopted stripe (changed in 1Password)"])
        XCTAssertEqual(labels(try XCTUnwrap(try sec("stripe")).1), ["key=v2"])
        XCTAssertEqual(try writes().count, writesBefore + 1)          // the item's tag follows the new content
        try replay()
        XCTAssertEqual(try? syncVault("V", store: laptop, cli: deps.onepassword, now: clock, memory: memory).get(), ["no changes"])
        // and a change on the Mac alone goes the other way
        try store("stripe", "default", "v3", description: nil)
        XCTAssertEqual(try? syncVault("V", store: laptop, cli: deps.onepassword, now: clock, memory: memory).get(), ["updated stripe"])
    }

    func testChangedOnBothSidesIsAConflictAndNeitherSideChanges() throws {
        let memory = try adoptedStripe()
        try store("stripe", "default", "mac", description: nil)
        try editInVault("h1", "vault")
        let before = try writes().count
        let r = try XCTUnwrap(try? syncVault("V", store: laptop, cli: deps.onepassword, now: clock, memory: memory).get())
        XCTAssertEqual(r.count, 1)
        XCTAssertTrue(r[0].hasPrefix("conflict stripe: changed in 1Password and on this Mac"), r[0])
        XCTAssertEqual(try writes().count, before)
        XCTAssertEqual(labels(try XCTUnwrap(try sec("stripe")).1), ["default=mac"].map { _ in "=mac" })
        // still a conflict next time
        XCTAssertTrue(try XCTUnwrap(try? syncVault("V", store: laptop, cli: deps.onepassword, now: clock, memory: memory).get())[0].hasPrefix("conflict stripe"))
    }

    func testAnItemDeletedInTheVaultIsWrittenAgainAndARemovedSecretIsArchived() throws {
        _ = try adoptedStripe()
        vault = []
        try publishVault()
        XCTAssertEqual(try? syncVault("V", store: laptop, cli: deps.onepassword, now: clock).get(), ["added stripe"])
        try replay()
        XCTAssertTrue(try laptop.delete(service: "stripe", account: "default"))
        XCTAssertEqual(try? syncVault("V", store: laptop, cli: deps.onepassword, now: clock).get(), ["removed stripe"])
    }

    func testAHandMadeItemNamingASecretTheSyncDoesNotOwnIsAConflictAtAnyLevel() throws {
        try putToken()
        try store("mine", "default", "keep", level: .personal)
        try store("srv", "default", "keep", level: .server)
        try handMade("p", "mine", fields: [["id": "1", "label": "k", "value": "other"]])
        try handMade("q", "srv", fields: [["id": "1", "label": "k", "value": "other"]])
        let r = try XCTUnwrap(try? syncVault("V", store: laptop, cli: deps.onepassword, now: clock).get())
        XCTAssertEqual(r.filter { $0.hasPrefix("conflict mine") || $0.hasPrefix("conflict srv") }.count, 2, "\(r)")
        XCTAssertEqual(labels(try XCTUnwrap(try sec("mine")).1), ["=keep"])
        XCTAssertEqual(labels(try XCTUnwrap(try sec("srv")).1), ["=keep"])
        XCTAssertFalse(try writes().contains { $0.args.contains("p") || $0.args.contains("q") })
    }

    func testAnAdoptionCutShortIsFinishedAndRmAdoptsNothing() throws {
        try putToken()
        try handMade("h1", "stripe", fields: [["id": "1", "label": "key", "value": "v1"]])
        // stored here, the item never rewritten
        try laptop.upsert(service: "stripe", account: "default", secret: SecretValue(fields: [("key", "v1")]), kind: "static", meta: nil,
                          description: "adopted", level: .server, marks: SyncMarks(origin: "1password:V"))
        XCTAssertEqual(try? syncVault("V", store: laptop, cli: deps.onepassword, now: clock).get(), ["adopted stripe"])
        // rm: items are archived, a hand-made one is neither adopted nor touched
        try replay()
        try handMade("h2", "other", fields: [["id": "1", "label": "key", "value": "z"]])
        XCTAssertEqual(run(["onepassword", "rm", "V"]).exitCode, 1)          // not on the list
        XCTAssertEqual(try? syncVault("V", store: laptop, cli: deps.onepassword, holding: .nothing).get(), ["removed stripe"])
        XCTAssertNil(try sec("other"))
    }

    func testAnItemJustCreatedIsNotCreatedAgainBeforeOnePasswordListsIt() throws {
        try putToken()
        try store("github", "ci", "x")
        let memory = VaultMemoryRef()
        XCTAssertEqual(try? syncVault("V", store: laptop, cli: deps.onepassword, now: clock, memory: memory).get(), ["added github.ci"])
        // not listed yet
        XCTAssertEqual(try? syncVault("V", store: laptop, cli: deps.onepassword, now: clock + 5, memory: memory).get(), ["no changes"])
        XCTAssertEqual(try writes().count, 1)
    }

    /// Against the real 1Password, only when MYTOKENS_REAL_OP_TOKEN (a service account token) and
    /// MYTOKENS_REAL_OP_VAULT are set: a scratch Login made by hand-shaped JSON is adopted, a change made
    /// in the vault flows back, and both sides remove it. Prints each step to stderr.
    func testRealVaultRoundTrip() throws {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["MYTOKENS_REAL_OP_TOKEN"], let v = env["MYTOKENS_REAL_OP_VAULT"] else { throw XCTSkip("no real op") }
        func say(_ s: String) { FileHandle.standardError.write(Data("REAL: \(s)\n".utf8)) }
        let real = OPCommand()
        var scratchID = ""
        /// A real vault holds items this test must never see: `item list` shows only the scratch item, and
        /// every call names the scratch item's id or creates one.
        struct ScratchOnly: OnePasswordCLI {
            var real: OPCommand
            var id: () -> String
            var title: String
            func run(_ args: [String], stdin: Data, token: String) throws -> CommandResult {
                if args.prefix(2) == ["item", "list"] {
                    var r = try real.run(args, stdin: stdin, token: token)
                    let all = (try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8))) as? [[String: Any]] ?? []
                    let kept = all.filter { $0["title"] as? String == title }
                    r.stdout = String(decoding: try JSONSerialization.data(withJSONObject: kept), as: UTF8.self)
                    return r
                }
                guard args.prefix(2) == ["item", "create"] || (args.count > 2 && args[2] == id()) else {
                    return CommandResult(stdout: "", stderr: "refused: \(args.prefix(3))", exitCode: 1)
                }
                return try real.run(args, stdin: stdin, token: token)
            }
        }
        let cli = ScratchOnly(real: real, id: { scratchID }, title: "mytokens-scratch-13")
        func op(_ args: [String], _ stdin: String = "") throws -> String {
            let r = try real.run(args, stdin: Data(stdin.utf8), token: token)
            XCTAssertEqual(r.exitCode, 0, "\(args): \(r.stderr)")
            return r.stdout
        }
        let title = "mytokens-scratch-13"
        try store(onePasswordTokenService, "default", token, level: .personal)
        let login = #"{"title":"\#(title)","category":"LOGIN","fields":[{"id":"username","label":"username","purpose":"USERNAME","type":"STRING","value":"felix"},{"id":"password","label":"password","purpose":"PASSWORD","type":"CONCEALED","value":"first-value"}],"tags":[]}"#
        let created = try op(["item", "create", "--vault", v, "--format", "json"], login)
        let id = try XCTUnwrap(((try JSONSerialization.jsonObject(with: Data(created.utf8))) as? [String: Any])?["id"] as? String)
        scratchID = id
        say("created Login \(title) id \(id) by hand-shaped JSON; waiting 12 s for 1Password to list it")
        Thread.sleep(forTimeInterval: 12)
        let memory = VaultMemoryRef()
        func sync() -> [String] {
            switch syncVault(v, store: laptop, cli: cli, now: Date(), memory: memory) {
            case .success(let l): return l
            case .failure(let f): return ["FAILED to \(f.step): \(f.why)"]
            }
        }
        func show() throws -> String {
            guard let (_, value) = try sec(title) else { return "(no such secret)" }
            return value.fields.map { "\($0.label)=\($0.value)" }.joined(separator: ", ")
        }
        defer { _ = try? real.run(["item", "delete", id, "--vault", v, "--archive"], stdin: Data(), token: token) }
        say("sync 1 → \(sync())")
        say("secret: \(try show()); level \(try sec(title)?.0.level.rawValue ?? "?"), origin \(try sec(title)?.0.origin ?? "?")")
        say("sync 2 (nothing changed) → \(sync())")
        _ = try op(["item", "edit", id, "--vault", v, "--format", "json"], login.replacingOccurrences(of: "first-value", with: "changed-in-vault"))
        say("changed the password in the vault by hand")
        say("sync 3 → \(sync())")
        say("secret: \(try show())")
        say("op read after the rewrite: \(try op(["read", "op://\(v)/\(title)/password"]).trimmingCharacters(in: .whitespacesAndNewlines))")
        XCTAssertTrue(try laptop.delete(service: title, account: "default"))
        say("removed the secret on the Mac; sync 4 → \(sync())")
        Thread.sleep(forTimeInterval: 3)
        let left = try op(["item", "list", "--vault", v, "--format", "json"])
        say("items titled \(title) still listed: \(left.contains(title))")
    }
}
