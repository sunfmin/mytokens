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
            if [ "$1 $2" = "service-account ratelimit" ]; then cat "$d/ratelimit.json" || exit 1; fi
            if [ "$1 $2" = "item create" ] && [ -f "$d/create-answers" ]; then printf '{"id":"id%s","version":1}' "$n"; fi

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
        XCTAssertEqual(try writes().count, 0)        // no second item titled srv is created either
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

    // MARK: the write budget, the create lag and the lock (mytokens#14)

    /// What `op service-account ratelimit --format json` says: `remaining` writes for the token and the account.
    private func ratelimit(writes remaining: Int) throws {
        let rows: [[String: Any]] = [
            ["type": "token", "action": "write", "limit": 100, "used": 100 - remaining, "remaining": remaining, "reset": 3000],
            ["type": "token", "action": "read", "limit": 1000, "used": 0, "remaining": 1000, "reset": 3000],
            ["type": "account", "action": "read_write", "limit": 1000, "used": 0, "remaining": 1000, "reset": 80000]]
        try JSONSerialization.data(withJSONObject: rows).write(to: URL(fileURLWithPath: dir + "/ratelimit.json"))
    }

    func testASyncWritesWhatFitsTheBudgetSaysSoInListAndGoesOnNextRun() throws {
        try putToken()
        for s in ["a", "b", "c"] { try store(s) }
        try ratelimit(writes: 2)
        XCTAssertEqual(run(["onepassword", "add", "Servers"]).exitCode, 0)
        XCTAssertEqual(try writes().count, 2)
        let list = run(["onepassword", "list"]).stdout
        XCTAssertTrue(list.contains("deferred c: the service account has no writes left"), list)
        try replay()
        // the next run, with room: the third is written, the first two are not written again
        try ratelimit(writes: 98)
        let mark = try writes().count
        let r = try XCTUnwrap(try? syncVault("Servers", store: laptop, cli: deps.onepassword, now: clock + 600, memory: VaultMemoryRef()).get())
        XCTAssertEqual(r, ["added c"])
        XCTAssertEqual(try writes().count - mark, 1)
    }

    func testAnUnchangedItemIsNeverWrittenEvenWhenTheBudgetIsGone() throws {
        try putToken()
        try store("a"); try store("b")
        XCTAssertEqual(run(["onepassword", "add", "Servers"]).exitCode, 0)
        try replay()
        try ratelimit(writes: 0)
        let mark = try writes().count
        XCTAssertEqual(try? syncVault("Servers", store: laptop, cli: deps.onepassword, now: clock + 600).get(), ["no changes"])
        try store("a", "default", "changed")
        let r = try XCTUnwrap(try? syncVault("Servers", store: laptop, cli: deps.onepassword, now: clock + 600).get())
        XCTAssertEqual(r.count, 1)
        XCTAssertTrue(r[0].hasPrefix("deferred a:"), "\(r)")
        XCTAssertEqual(try writes().count, mark)
    }

    func testRmKeepsTheVaultOnTheListWhenTheBudgetRunsOutBeforeItIsEmpty() throws {
        try putToken()
        try store("a"); try store("b")
        XCTAssertEqual(run(["onepassword", "add", "Servers"]).exitCode, 0)
        try replay()
        try ratelimit(writes: 1)
        let r = run(["onepassword", "rm", "Servers"])
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertTrue(r.stderr.contains("it stays on the vault list"), r.stderr)
        XCTAssertEqual(try vaults.read(), ["Servers"])
    }

    func testAnOpThatDoesNotSayHowManyWritesAreLeftHoldsNothingBack() throws {
        try putToken()
        for s in ["a", "b", "c"] { try store(s) }       // no ratelimit.json: the fake op fails the call
        XCTAssertEqual(run(["onepassword", "add", "Servers"]).exitCode, 0)
        XCTAssertEqual(try writes().count, 3)
    }

    func testTheIdOfACreatedItemIsKeptUntilItIsListedAndNothingIsCreatedTwice() throws {
        try putToken()
        try FileManager.default.createFile(atPath: dir + "/create-answers", contents: Data())
        try store("github", "ci", "x")
        let memory = VaultMemoryRef()
        XCTAssertEqual(try? syncVault("V", store: laptop, cli: deps.onepassword, now: clock, memory: memory).get(), ["added github.ci"])
        let id = try XCTUnwrap(memory.value.createdIds?["github.ci"])
        XCTAssertNotNil(memory.value.items[id])
        // two syncs 2 s apart, 1Password not listing it yet: held, no write, the id still known
        XCTAssertEqual(try? syncVault("V", store: laptop, cli: deps.onepassword, now: clock + 2, memory: memory).get(), ["no changes"])
        XCTAssertEqual(try? syncVault("V", store: laptop, cli: deps.onepassword, now: clock + 4, memory: memory).get(), ["no changes"])
        XCTAssertNotNil(memory.value.items[id])
        XCTAssertEqual(try writes().count, 1)
        // now listed (same version as the create said): no read, no write
        try replay()
        let reads = try gets().count
        XCTAssertEqual(try? syncVault("V", store: laptop, cli: deps.onepassword, now: clock + 12, memory: memory).get(), ["no changes"])
        XCTAssertEqual(try gets().count, reads)
        XCTAssertEqual(try writes().count, 1)
        // long after, the lag window is forgotten
        XCTAssertEqual(try? syncVault("V", store: laptop, cli: deps.onepassword, now: clock + 600, memory: memory).get(), ["no changes"])
        XCTAssertNil(memory.value.createdIds)
    }

    func testVaultMemoryWrittenBeforeCreatedIdsExistedStillReads() throws {
        let old = #"{"items":{"i1":{"version":2,"digest":"d"}},"created":{"x":1.0}}"#
        let m = try JSONDecoder().decode(VaultMemory.self, from: Data(old.utf8))
        XCTAssertEqual(m.items["i1"]?.version, 2)
        XCTAssertNil(m.createdIds)
    }

    /// A state that counts how many runs hold the lock, and how many at once.
    private final class CountingState: BackgroundSyncState {
        let inner = MemoryBackgroundSyncState()
        var holding = 0, held = 0
        func statuses() -> [String: HostSyncStatus] { inner.statuses() }
        func save(_ statuses: [String: HostSyncStatus]) throws { try inner.save(statuses) }
        func isPaused() -> Bool { inner.isPaused() }
        func setPaused(_ paused: Bool) throws { try inner.setPaused(paused) }
        func exclusively(_ body: () -> Void) { holding += 1; held += 1; body(); holding -= 1 }
        func markPending() { inner.markPending() }
        func takePending() -> Bool { inner.takePending() }
    }

    func testAddAndRmSyncTheVaultOnlyWhileHoldingTheRunLock() throws {
        try putToken()
        try store("a")
        let counting = CountingState()
        var d = deps
        d.syncState = counting
        XCTAssertEqual(runCommand(["onepassword", "add", "Servers"], d).exitCode, 0)
        XCTAssertEqual(counting.held, 1)
        XCTAssertEqual(counting.holding, 0)
        try replay()
        XCTAssertEqual(runCommand(["onepassword", "rm", "Servers"], d).exitCode, 0)
        XCTAssertEqual(counting.held, 2)
    }

    // `onepassword keep <vault> <title> mac|1password` settles one conflict (mytokens#16).

    /// `stripe` adopted from the listed vault V, then changed on this Mac (`mac`) and in 1Password (`vault`):
    /// the last sync (as `onepassword add`, recorded in the state) reported the conflict.
    private func stripeInConflict() throws {
        try putToken()
        try handMade("h1", "stripe", fields: [["id": "1", "label": "key", "value": "v1"]])
        XCTAssertEqual(run(["onepassword", "add", "V"]).stdout, "adopted stripe\nadded V to the vault list\n")
        try replay()
        XCTAssertEqual(run(["onepassword", "add", "V"]).stdout, "no changes\nV is on the vault list\n")
        try store("stripe", fields: [("key", "mac")])
        try editInVault("h1", "vault")
        let r = run(["onepassword", "add", "V"])
        XCTAssertTrue(r.stdout.hasPrefix("conflict stripe: changed in 1Password and on this Mac"), r.stdout)
    }

    func testAConflictLineNamesTheKeepCommandInListAndInTheSyncOutput() throws {
        try stripeInConflict()
        let hint = "settle it: mytokens onepassword keep V stripe mac|1password"
        XCTAssertTrue(run(["onepassword", "list"]).stdout.contains("conflict stripe: changed in 1Password and on this Mac since the last sync; neither changed; " + hint),
                      run(["onepassword", "list"]).stdout)
        XCTAssertTrue(run(["server", "sync"]).stdout.contains(hint))
        // a title or vault that needs quoting is quoted
        XCTAssertEqual(vaultKeepHint("my vault", "a b"), "settle it: mytokens onepassword keep 'my vault' 'a b' mac|1password")
    }

    func testKeepMacWritesTheMacsSecretOverTheItemAndTheNextSyncSaysNothing() throws {
        try stripeInConflict()
        let before = try writes().count
        let r = run(["onepassword", "keep", "V", "stripe", "mac"])
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        XCTAssertEqual(r.stdout, "kept this Mac's stripe (written over 1Password's)\n")
        XCTAssertEqual(try writes().count, before + 1)
        XCTAssertTrue(try writes().last!.stdin.contains("\"mac\""))
        XCTAssertEqual(labels(try XCTUnwrap(try sec("stripe")).1), ["key=mac"])
        try replay()
        XCTAssertEqual(run(["onepassword", "add", "V"]).stdout, "no changes\nV is on the vault list\n")
        XCTAssertEqual(run(["onepassword", "list"]).stdout.contains("conflict"), false)
        XCTAssertEqual(run(["onepassword", "keep", "V", "stripe", "mac"]).exitCode, 1)    // settled: nothing to keep
    }

    func testKeepOnePasswordAdoptsTheItemOverTheSecretAndTheNextSyncSaysNothing() throws {
        try stripeInConflict()
        let r = run(["onepassword", "keep", "V", "stripe", "1password"])
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        XCTAssertEqual(r.stdout, "kept 1Password's stripe (adopted over this Mac's)\n")
        let (rec, value) = try XCTUnwrap(try sec("stripe"))
        XCTAssertEqual(labels(value), ["key=vault"])
        XCTAssertEqual(rec.level, .server)
        try replay()
        XCTAssertEqual(run(["onepassword", "add", "V"]).stdout, "no changes\nV is on the vault list\n")
        XCTAssertFalse(run(["onepassword", "list"]).stdout.contains("conflict"))
    }

    func testKeepIsRefusedWithoutAConflictAndTouchesNothing() throws {
        try stripeInConflict()
        try store("other", "default", "x")
        _ = run(["onepassword", "add", "V"])
        let before = try calls().count
        for (argv, code) in [(["onepassword", "keep", "V", "other", "mac"], Int32(1)),         // no conflict on it
                             (["onepassword", "keep", "W", "stripe", "mac"], 1),               // not a listed vault
                             (["onepassword", "keep", "V", "stripe", "both"], 64),             // no such side
                             (["onepassword", "keep", "V", "stripe"], 64)] {
            let r = run(argv)
            XCTAssertEqual(r.exitCode, code, "\(argv): \(r.stderr)")
        }
        XCTAssertTrue(run(["onepassword", "keep", "V", "other", "1password"]).stderr.contains("no conflict on other in the vault V"))
        XCTAssertEqual(try calls().count, before)
        XCTAssertEqual(labels(try XCTUnwrap(try sec("stripe")).1), ["key=mac"])
    }

    func testKeepSettlesAHandMadeItemNamingASecretTheSyncDoesNotOwn() throws {
        try putToken()
        try vaults.write(["V"])
        try store("mine", "default", "keep", level: .personal)
        try store("srv", "default", "keep", level: .server)
        try store("ours", "default", "keep", level: .personal)
        try handMade("p", "mine", fields: [["id": "1", "label": "k", "value": "other"]])
        try handMade("q", "srv", fields: [["id": "1", "label": "k", "value": "other"]])
        try handMade("r", "ours", fields: [["id": "1", "label": "k", "value": "theirs"]])
        let conflicts = run(["server", "sync"]).stdout
        for t in ["mine", "srv", "ours"] {
            XCTAssertTrue(conflicts.contains("conflict \(t): a Secret of that name is on this Mac and the sync does not own it; neither changed; settle it: mytokens onepassword keep V \(t) mac|1password"), conflicts)
        }
        /// What `keep` said of `title` (each `keep` is a whole sync: the other conflicts are said too), the vault then replayed.
        func keep(_ title: String, _ side: String) throws -> [String] {
            let r = run(["onepassword", "keep", "V", title, side])
            XCTAssertEqual(r.exitCode, 0, r.stderr)
            try replay()
            return r.stdout.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("conflict ") }
        }
        // mac, server-level: the Secret is written over the item, which the sync then owns
        XCTAssertEqual(try keep("srv", "mac"), ["kept this Mac's srv (written over 1Password's)"])
        XCTAssertTrue(try writes().contains { $0.args.prefix(3) == ["item", "edit", "q"] && $0.stdin.contains("\"keep\"") })
        // mac, personal: the item is archived, the Secret stays personal
        XCTAssertEqual(try keep("mine", "mac"), ["kept this Mac's mine (personal-level, so not in the vault: 1Password's archived)"])
        XCTAssertTrue(try writes().contains { $0.args.prefix(3) == ["item", "delete", "p"] })
        XCTAssertEqual(try XCTUnwrap(try sec("mine")).0.level, .personal)
        // 1password: Adopted over the Secret, server-level and the sync's
        XCTAssertEqual(try keep("ours", "1password"), ["kept 1Password's ours (adopted over this Mac's)"])
        let (rec, value) = try XCTUnwrap(try sec("ours"))
        XCTAssertEqual(labels(value), ["k=theirs"])
        XCTAssertEqual(rec.level, .server)
        XCTAssertEqual(rec.origin, vaultOriginKey("V"))
        XCTAssertEqual(run(["server", "sync"]).stdout.split(separator: "\n").last, "1Password vault V: no changes")
    }
}
