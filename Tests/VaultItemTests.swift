import CryptoKit
import XCTest

// A Secret ⇄ a 1Password vault item (ADR-0022, mytokens#10): the encoding is lossless, and a
// server with only `op` and `jq` reads the same bytes mytokens itself prints.
final class VaultItemTests: XCTestCase {
    private var store = InMemorySecretStore()

    override func setUp() { store = InMemorySecretStore() }

    private var deps: Dependencies { Dependencies(store: store, input: CannedSecretInput(value: nil)) }

    fileprivate func put(_ service: String, _ account: String = "default", secret: SecretValue, kind: String = "static", meta: Any? = nil,
                     description: String? = nil, level: Level = .server) throws {
        try store.upsert(service: service, account: account, secret: secret, kind: kind, meta: meta, description: description,
                         level: level, marks: SyncMarks())
    }

    private func item(_ service: String, _ account: String = "default") throws -> VaultItem {
        let r = try XCTUnwrap(try store.list().first { $0.service == service && $0.account == account })
        return VaultItem(service: r.service, account: r.account, kind: r.kind, meta: r.meta, description: r.description,
                         level: r.level, secret: try XCTUnwrap(try store.get(service: service, account: account)))
    }

    private func assertRoundTrip(_ service: String, _ account: String = "default", file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try item(service, account)
        let after = try decodeVaultItem(before.template())
        XCTAssertEqual(after.service, before.service, file: file, line: line)
        XCTAssertEqual(after.account, before.account, file: file, line: line)
        XCTAssertEqual(after.kind, before.kind, file: file, line: line)
        XCTAssertEqual(after.meta, before.meta, file: file, line: line)
        XCTAssertEqual(after.description, before.description, file: file, line: line)
        XCTAssertEqual(after.level, before.level, file: file, line: line)
        XCTAssertEqual(after.secret.fields.map(\.label), before.secret.fields.map(\.label), file: file, line: line)
        XCTAssertEqual(after.secret.fields.map(\.value), before.secret.fields.map(\.value), file: file, line: line)
        XCTAssertEqual(after.secret.lists, before.secret.lists, file: file, line: line)
        XCTAssertEqual(after.secret.isLabelled, before.secret.isLabelled, file: file, line: line)
    }

    // MARK: round trips

    func testALoneValueRoundTrips() throws {
        try put("github", secret: SecretValue(single: "ghp_x"))
        try assertRoundTrip("github")
    }

    func testSeveralLabelledFieldsRoundTripInOrder() throws {
        try put("aws", secret: SecretValue(fields: [("SecretAccessKey", "sk/2"), ("AccessKeyId", "AKIA1"), ("Region", "")]))
        try assertRoundTrip("aws")
    }

    func testALoneLabelledFieldNamedValueIsNotABareValue() throws {
        try put("a", secret: SecretValue(fields: [("value", "v")]))
        try put("b", secret: SecretValue(single: "v"))
        XCTAssertTrue(try decodeVaultItem(try item("a").template()).secret.isLabelled)
        XCTAssertFalse(try decodeVaultItem(try item("b").template()).secret.isLabelled)
        try assertRoundTrip("a")
    }

    func testAProfileRoundTrips() throws {
        try put("glm", secret: SecretValue(fields: [("ANTHROPIC_BASE_URL", "https://x.example/api"), ("ANTHROPIC_AUTH_TOKEN", "it's")]), kind: "profile")
        try assertRoundTrip("glm")
        XCTAssertEqual(try decodeVaultItem(try item("glm").template()).kind, "profile")
    }

    func testAParentTokenWithMetaRoundTrips() throws {
        try put("cloudflare", secret: SecretValue(single: "cf"), kind: "parent", meta: ["account_id": "abc/1", "default_ttl_seconds": 3600])
        try assertRoundTrip("cloudflare")
        XCTAssertEqual(try decodeVaultItem(try item("cloudflare").template()).kind, "parent")
        XCTAssertNotNil(try decodeVaultItem(try item("cloudflare").template()).meta)
    }

    func testAListFieldRoundTrips() throws {
        let list = try XCTUnwrap(ListValue.canonical(#"[{"user":"app","host":"db1","password":"p/1"},{"host":"db2","user":"app","password":"p2"}]"#))
        try put("db", "prod", secret: SecretValue(fields: [("Hosts", list)], lists: ["Hosts"]))
        try assertRoundTrip("db", "prod")
    }

    func testASecretWithBothListAndStringFieldsRoundTripsInOrder() throws {
        let list = try XCTUnwrap(ListValue.canonical(#"[{"a":"1"},{"a":"2"},{"a":"3"}]"#))
        try put("mix", secret: SecretValue(fields: [("Token", "t"), ("Hosts [1]", "tricky"), ("Hosts", list), ("Zed", "z")], lists: ["Hosts"]))
        try assertRoundTrip("mix")
    }

    func testANonDefaultAccountAndADottedServiceRoundTrip() throws {
        try put("guild-hub.mac-studio", "ci.2", secret: SecretValue(single: "x"), level: .personal)
        let back = try decodeVaultItem(try item("guild-hub.mac-studio", "ci.2").template())
        XCTAssertEqual(back.service, "guild-hub.mac-studio")
        XCTAssertEqual(back.account, "ci.2")
        XCTAssertEqual(back.level, .personal)
        try assertRoundTrip("guild-hub.mac-studio", "ci.2")
    }

    func testADescriptionWithNewlinesAndCJKRoundTrips() throws {
        try put("cn", secret: SecretValue(fields: [("令牌", "值\n第二行"), ("k", "v")]), description: "部署用令牌\nsecond line: “quotes” & emoji 🔑")
        try assertRoundTrip("cn")
        XCTAssertEqual(try decodeVaultItem(try item("cn").template()).description, "部署用令牌\nsecond line: “quotes” & emoji 🔑")
    }

    func testNoDescriptionRoundTripsAsNone() throws {
        try put("nodesc", secret: SecretValue(single: "x"))
        XCTAssertNil(try decodeVaultItem(try item("nodesc").template()).description)
    }

    // MARK: the format

    private func template(_ i: VaultItem) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: i.template()) as? [String: Any])
    }

    func testFieldsStayPlainTopLevelAndMetadataIsInItsOwnSection() throws {
        try put("app", secret: SecretValue(fields: [("kind", "FIELD"), ("level", "FIELD2")]), kind: "static")
        let t = try template(try item("app"))
        let fields = try XCTUnwrap(t["fields"] as? [[String: Any]])
        let top = fields.filter { $0["section"] == nil && $0["purpose"] == nil }
        XCTAssertEqual(top.map { $0["label"] as? String }, ["kind", "level"])      // `op read .../kind` is the Field
        XCTAssertTrue(top.allSatisfy { $0["type"] as? String == "CONCEALED" })
        let meta = fields.filter { ($0["section"] as? [String: Any])?["label"] as? String == "mytokens" }
        XCTAssertTrue(meta.allSatisfy { $0["type"] as? String == "STRING" })
        XCTAssertEqual(Set(meta.compactMap { $0["label"] as? String }), ["service", "account", "kind", "level", "shape", "order"])
        XCTAssertEqual(meta.first { $0["label"] as? String == "kind" }?["value"] as? String, "static")
        let back = try decodeVaultItem(try item("app").template())
        XCTAssertEqual(back.secret.value(forField: "kind"), "FIELD")
        XCTAssertEqual(back.kind, "static")
    }

    func testTheDigestTagCoversEverythingAnItemHoldsAndOldFormatItemsDiffer() throws {
        try put("a", secret: SecretValue(single: "x"), kind: "static")
        let base = try item("a")
        var changed = base; changed.kind = "parent"
        XCTAssertNotEqual(base.digest, changed.digest)
        changed = base; changed.level = .personal
        XCTAssertNotEqual(base.digest, changed.digest)
        changed = base; changed.meta = #"{"a":1}"#
        XCTAssertNotEqual(base.digest, changed.digest)
        changed = base; changed.secret = SecretValue(fields: [("", "x")])
        XCTAssertEqual(base.digest, changed.digest)
        changed = base; changed.secret = SecretValue(fields: [("value", "x")])
        XCTAssertNotEqual(base.digest, changed.digest)
        // The digest an item written before this format carried: title, notes, fields.
        let old: [Any] = ["a", "", [["value", "x"]]]
        let oldDigest = SHA256Hex(try JSONSerialization.data(withJSONObject: old, options: [.sortedKeys]))
        XCTAssertNotEqual(base.digest, oldDigest)
    }

    // MARK: a server with op and jq only

    fileprivate var programs: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("skills/mytokens/op").path
    }

    fileprivate func jqPath() throws -> String {
        let home = NSHomeDirectory()
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            if FileManager.default.isExecutableFile(atPath: dir + "/jq") { return dir + "/jq" }
        }
        throw XCTSkip("jq is missing: make jq-install")
    }

    /// Runs a program of skills/mytokens/op on the item as `op item get --format json` would print it.
    private func jq(_ program: String, _ i: VaultItem, flags: String = "-cSj", args: [String] = []) throws -> CommandResult {
        try runProcess(try jqPath(), [flags, "-L", programs] + args + ["-f", programs + "/" + program], stdin: i.template())
    }

    fileprivate func mytokens(_ argv: [String]) -> CommandResult { runCommand(argv, deps) }

    private func accountArgs(_ a: String) -> [String] { a == "default" ? [] : ["--account", a] }

    private func assertSecretMatches(_ service: String, _ account: String = "default", file: StaticString = #filePath, line: UInt = #line) throws {
        let ours = mytokens(["get", service, "--json"] + accountArgs(account))
        XCTAssertEqual(ours.exitCode, 0, ours.stderr, file: file, line: line)
        let theirs = try jq("secret.jq", try item(service, account))
        XCTAssertEqual(theirs.exitCode, 0, theirs.stderr, file: file, line: line)
        XCTAssertEqual(theirs.stdout, ours.stdout, file: file, line: line)
    }

    func testJqReadsAWholeSecretAsMytokensGetJSON() throws {
        try put("github", secret: SecretValue(single: "ghp_ü/x\"\\"))
        try put("aws", "prod", secret: SecretValue(fields: [("SecretAccessKey", "sk/2"), ("AccessKeyId", "AKIA1")]), level: .personal)
        try put("cn", secret: SecretValue(fields: [("令牌", "值\n第二行 'q' $x"), ("k", "")]), description: "说明\n两行")
        let list = try XCTUnwrap(ListValue.canonical(#"[{"user":"app","host":"db1","password":"p/1"},{"host":"db2","user":"app","password":"p2"}]"#))
        try put("db", secret: SecretValue(fields: [("Token", "t"), ("Hosts", list), ("Other", "o")], lists: ["Hosts"]))
        try put("tricky", secret: SecretValue(fields: [("Hosts [1]", "x"), ("kind", "FIELD"), ("order", "[]")]))
        for (s, a) in [("github", "default"), ("aws", "prod"), ("cn", "default"), ("db", "default"), ("tricky", "default")] {
            try assertSecretMatches(s, a)
        }
    }

    func testJqReadsAProfileAsMytokensEnv() throws {
        try put("glm", secret: SecretValue(fields: [("ANTHROPIC_BASE_URL", "https://x.example/api"), ("ANTHROPIC_AUTH_TOKEN", "it's a 'quote'\nand $(cmd) `x`"),
                                                    ("A_FIRST", "z")]), kind: "profile")
        let ours = mytokens(["env", "glm"])
        XCTAssertEqual(ours.exitCode, 0, ours.stderr)
        let theirs = try jq("env.jq", try item("glm"), flags: "-rj")
        XCTAssertEqual(theirs.exitCode, 0, theirs.stderr)
        XCTAssertEqual(theirs.stdout, ours.stdout)
    }

    func testJqRefusesToRenderANonProfileAsEnv() throws {
        try put("github", secret: SecretValue(fields: [("a", "b")]))
        XCTAssertNotEqual(try jq("env.jq", try item("github"), flags: "-rj").exitCode, 0)
    }

    func testJqReadsAListFieldAsMytokensGetField() throws {
        let list = try XCTUnwrap(ListValue.canonical(#"[{"user":"app","host":"db1","password":"p/1"},{"host":"db2","user":"ü","password":"p2"}]"#))
        try put("db", "prod", secret: SecretValue(fields: [("Token", "t"), ("Hosts", list)], lists: ["Hosts"]))
        for label in ["Hosts", "Token"] {
            let ours = mytokens(["get", "db", "--account", "prod", "--field", label])
            let theirs = try jq("field.jq", try item("db", "prod"), args: ["--arg", "label", label])
            XCTAssertEqual(ours.exitCode, 0, ours.stderr)
            XCTAssertEqual(theirs.stdout, ours.stdout, theirs.stderr)
        }
    }

    func testJqReadsMoreThanNineRecordsInOrder() throws {
        let records = (1...12).map { #"{"n":"\#($0)"}"# }.joined(separator: ",")
        let list = try XCTUnwrap(ListValue.canonical("[\(records)]"))
        try put("many", secret: SecretValue(fields: [("L", list)], lists: ["L"]))
        let ours = mytokens(["get", "many", "--field", "L"])
        let theirs = try jq("field.jq", try item("many"), args: ["--arg", "label", "L"])
        XCTAssertEqual(theirs.stdout, ours.stdout, theirs.stderr)
    }
}

private func SHA256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
}

// Items as a real 1Password prints them (`op item get --format json`, written to the `devbox` vault
// by the sync's own template and read back, 2026-11-18, mytokens#10).
extension VaultItemTests {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/op-item-\(name).json"))
    }

    func testARealOpItemDecodesAndJqReadsItLikeMytokens() throws {
        let list = try decodeVaultItem(try fixture("list"))
        XCTAssertEqual(list.service, "scratch-10-list")
        XCTAssertEqual(list.secret.labels, ["Token", "Hosts"])
        XCTAssertEqual(list.secret.lists, ["Hosts"])
        XCTAssertEqual(list.secret.value(forField: "Hosts"), #"[{"host":"db1","password":"p/1","user":"app"},{"host":"db2","password":"p2","user":"u"}]"#)
        let profile = try decodeVaultItem(try fixture("profile"))
        XCTAssertEqual(profile.kind, "profile")
        XCTAssertEqual(profile.description, "p")
        XCTAssertEqual(profile.secret.labels, ["B_VAR", "A_VAR"])
        // jq on the real item and mytokens on the decoded Secret print the same bytes.
        try put("scratch-10-profile", secret: profile.secret, kind: "profile", description: "p")
        let ours = mytokens(["env", "scratch-10-profile"])
        let theirs = try runProcess(try jqPath(), ["-rj", "-L", programs, "-f", programs + "/env.jq"], stdin: try fixture("profile"))
        XCTAssertEqual(theirs.stdout, ours.stdout, theirs.stderr)
        try put("scratch-10-list", secret: list.secret)
        let secret = try runProcess(try jqPath(), ["-cSj", "-L", programs, "-f", programs + "/secret.jq"], stdin: try fixture("list"))
        XCTAssertEqual(secret.stdout, mytokens(["get", "scratch-10-list", "--json"]).stdout, secret.stderr)
    }
}
