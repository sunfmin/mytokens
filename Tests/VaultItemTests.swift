import XCTest

/// An item (a template, or what `op item get` printed) without what marks it the sync's own (ADR-0026):
/// the tag `mytokens`, the field `digest` of the section `mytokens` and that section.
func withoutOwnMark(_ item: [String: Any]) -> [String: Any] {
    var item = item
    item["tags"] = (item["tags"] as? [String])?.filter { $0 != vaultItemTag }
    item["fields"] = (item["fields"] as? [[String: Any]])?.filter { f in
        !((f["section"] as? [String: Any])?["id"] as? String == vaultOwnSection && f["label"] as? String == vaultDigestLabel)
    }
    item["sections"] = (item["sections"] as? [[String: Any]])?.filter { $0["id"] as? String != vaultOwnSection }
    return item
}

/// The digest an item carries in its field `digest` of the section `mytokens`, if any.
func ownDigest(_ item: [String: Any]) -> String? {
    (item["fields"] as? [[String: Any]])?.first { f in
        (f["section"] as? [String: Any])?["id"] as? String == vaultOwnSection && f["label"] as? String == vaultDigestLabel
    }?["value"] as? String
}

// A `server`-level Secret ⇄ a 1Password vault item in optokens' layout (ADR-0024): the item the sync
// writes is the one optokens writes for the same Secret, and decodes back to that Secret.
final class VaultItemTests: XCTestCase {
    private var store = InMemorySecretStore()

    override func setUp() { store = InMemorySecretStore() }

    private func put(_ service: String, _ account: String = "default", secret: SecretValue, kind: String = "static", meta: Any? = nil,
                     description: String? = nil) throws {
        try store.upsert(service: service, account: account, secret: secret, kind: kind, meta: meta, description: description,
                         level: .server, marks: SyncMarks())
    }

    private func item(_ service: String, _ account: String = "default") throws -> VaultItem {
        let r = try XCTUnwrap(try store.list().first { $0.service == service && $0.account == account })
        return VaultItem(service: r.service, account: r.account, kind: r.kind, meta: r.meta, description: r.description,
                         secret: try XCTUnwrap(try store.get(service: service, account: account)))
    }

    private func assertSame(_ after: VaultItem, _ before: VaultItem, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(after.service, before.service, file: file, line: line)
        XCTAssertEqual(after.account, before.account, file: file, line: line)
        XCTAssertEqual(after.kind, before.kind, file: file, line: line)
        XCTAssertEqual(after.meta, before.meta, file: file, line: line)
        XCTAssertEqual(after.description, before.description, file: file, line: line)
        XCTAssertEqual(after.secret.fields.map(\.label), before.secret.fields.map(\.label), file: file, line: line)
        XCTAssertEqual(after.secret.fields.map(\.value), before.secret.fields.map(\.value), file: file, line: line)
        XCTAssertEqual(after.secret.isLabelled, before.secret.isLabelled, file: file, line: line)
        XCTAssertEqual(after.digest, before.digest, file: file, line: line)
    }

    private func assertRoundTrip(_ service: String, _ account: String = "default", file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try item(service, account)
        assertSame(try decodeVaultItem(before.template()), before, file: file, line: line)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func fields(_ data: Data) throws -> [[String: Any]] { try XCTUnwrap(try json(data)["fields"] as? [[String: Any]]) }

    private func values(_ data: Data) throws -> [[String: Any]] {
        try fields(data).filter { ($0["section"] as? [String: Any])?["id"] as? String == "fields" }
    }

    // MARK: the item optokens writes

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/optokens-\(name).json"))
    }

    /// An item with every `id` dropped, and without what mytokens adds beside optokens' own.
    private func comparable(_ data: Data) throws -> NSDictionary {
        var item = withoutOwnMark(try json(data))
        item["fields"] = (item["fields"] as? [[String: Any]])?.map { f -> [String: Any] in var f = f; f["id"] = nil; return f }
        return item as NSDictionary
    }

    // MARK: what marks an item the sync's own (ADR-0026)

    func testTheSyncsItemCarriesItsDigestInAFieldNotATag() throws {
        try put("app", secret: SecretValue(fields: [("Region", "eu"), ("digest", "a Field of that label")]))
        let t = try json(try item("app").template())
        XCTAssertEqual(t["tags"] as? [String], ["optokens", "mytokens"])
        XCTAssertEqual(ownDigest(t), try item("app").digest)
        let own = try fields(try item("app").template()).filter { ($0["section"] as? [String: Any])?["id"] as? String == "mytokens" }
        XCTAssertEqual(own.map { "\($0["label"]!)=\($0["type"]!)" }, ["digest=STRING"])
        XCTAssertTrue((t["sections"] as? [[String: String]])?.contains(["id": "mytokens", "label": "mytokens"]) == true)
        // the digest is not the Secret's: it decodes back to the same Secret, and a Field named so stays a Field
        assertSame(try decodeVaultItem(try item("app").template()), try item("app"))
        XCTAssertEqual(vaultWrittenDigest(try item("app").template()), try item("app").digest)
    }

    func testARewriteKeepsOtherTagsAndDropsAnOldDigestTag() throws {
        try put("app", secret: SecretValue(single: "v"))
        var stored = try json(try item("app").template())
        stored["tags"] = ["team", "mytokens", "mytokens-digest-0123", "optokens"]
        stored["fields"] = (stored["fields"] as! [[String: Any]]).map { f in
            var f = f; if f["label"] as? String == "digest" { f["value"] = "stale" }; return f
        }
        let storedData = try JSONSerialization.data(withJSONObject: stored)
        for t in [try json(try item("app").template(forEdit: true, over: storedData)),
                  try json(try XCTUnwrap(vaultOwnTemplate(storedData, digest: try item("app").digest)))] {
            XCTAssertEqual(t["tags"] as? [String], ["optokens", "mytokens", "team"])
            XCTAssertEqual(ownDigest(t), try item("app").digest)
            XCTAssertEqual((t["fields"] as? [[String: Any]])?.filter { $0["label"] as? String == "digest" }.count, 1)
            XCTAssertEqual((t["sections"] as? [[String: Any]])?.filter { $0["id"] as? String == "mytokens" }.count, 1)
        }
        // an item an older mytokens wrote says its digest by its tag
        var old = stored
        old["fields"] = (stored["fields"] as! [[String: Any]]).filter { $0["label"] as? String != "digest" }
        XCTAssertEqual(vaultWrittenDigest(try JSONSerialization.data(withJSONObject: old)), "0123")
        old["tags"] = ["optokens", "mytokens"]
        XCTAssertNil(vaultWrittenDigest(try JSONSerialization.data(withJSONObject: old)))
    }

    /// The fixtures are what optokens 0.1.8 handed `op item create` (an `op` stand-in on PATH recorded its
    /// stdin) after `optokens put` of the same Secret; the bare ones are built by optokens' `item::template`
    /// rules (a bare `put` takes its value on a one-time link only). The sync writes each new Field
    /// CONCEALED; a Field optokens took from `--set` is STRING, and a rewrite over it keeps that.
    func testTheItemTheSyncWritesIsTheItemOptokensWritesAndDecodesBack() throws {
        let cases: [(String, VaultItem)] = [
            ("bare", VaultItem(service: "fx-bare", account: "default", kind: "static", meta: nil, description: nil,
                               secret: SecretValue(single: "v/1 'q'"))),
            ("bare-meta", VaultItem(service: "fx-bare-meta", account: "default", kind: "static", meta: #"{"account_id":"abc/1","ttl":3600}"#,
                                    description: "部署用\nsecond line", secret: SecretValue(single: "v/1 'q'"))),
            ("fields", VaultItem(service: "fx-fields", account: "ci", kind: "static", meta: nil, description: "CI deploy",
                                 secret: SecretValue(fields: [("Region", "us-east-1"), ("Endpoint", "https://x.example/a"), ("Secret Key", "sk/2")]))),
            ("profile-meta", VaultItem(service: "fx-profile", account: "default", kind: "profile", meta: #"{"account_id":"abc/1","n":[1,2],"zone":"b"}"#,
                                       description: nil, secret: SecretValue(fields: [("B_VAR", "it's"), ("A_VAR", "x y")]))),
        ]
        for (name, secret) in cases {
            let theirs = try fixture(name)
            XCTAssertEqual(try comparable(secret.template(over: theirs)), try comparable(theirs), name)
            assertSame(try decodeVaultItem(theirs), secret)
            assertSame(try decodeVaultItem(secret.template()), secret)
            // a new item: every Field CONCEALED, the rest as optokens writes it
            let fresh = try comparable(secret.template()).mutableCopy() as! NSMutableDictionary
            let mine = try comparable(theirs).mutableCopy() as! NSMutableDictionary
            for item in [fresh, mine] {
                item["fields"] = (item["fields"] as! [[String: Any]]).map { f -> [String: Any] in
                    var f = f
                    if (f["section"] as? [String: Any])?["id"] as? String == "fields" { f["type"] = "CONCEALED" }
                    return f
                }
            }
            XCTAssertEqual(fresh, mine, name)
        }
    }

    func testAFieldKeepsTheTypeTheVaultGivesItAndANewFieldIsConcealed() throws {
        try put("app", secret: SecretValue(fields: [("Region", "eu"), ("Token", "t")]))
        let first = try item("app").template()
        XCTAssertEqual(try values(first).map { $0["type"] as? String }, ["CONCEALED", "CONCEALED"])
        // someone shows Region in 1Password; the Secret then gains a Field
        var stored = try json(first)
        stored["fields"] = try fields(first).map { f -> [String: Any] in
            var f = f
            if f["label"] as? String == "Region" { f["type"] = "STRING" }
            return f
        }
        let edited = try JSONSerialization.data(withJSONObject: stored)
        try put("app", secret: SecretValue(fields: [("Region", "us"), ("Token", "t2"), ("New", "n")]))
        let again = try item("app").template(forEdit: true, over: edited)
        XCTAssertEqual(try values(again).map { $0["label"] as? String }, ["Region", "Token", "New"])
        XCTAssertEqual(try values(again).map { $0["type"] as? String }, ["STRING", "CONCEALED", "CONCEALED"])
        XCTAssertEqual(try item("app").digest, try decodeVaultItem(again).digest)     // a type is not content
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
        XCTAssertNotEqual(try item("a").digest, try item("b").digest)
        try assertRoundTrip("a")
    }

    func testAProfileWithMetaRoundTrips() throws {
        try put("glm", secret: SecretValue(fields: [("ANTHROPIC_BASE_URL", "https://x.example/api"), ("ANTHROPIC_AUTH_TOKEN", "it's")]),
                kind: "profile", meta: ["account_id": "abc/1", "default_ttl_seconds": 3600])
        try assertRoundTrip("glm")
        XCTAssertEqual(try decodeVaultItem(try item("glm").template()).meta, #"{"account_id":"abc/1","default_ttl_seconds":3600}"#)
    }

    func testANonDefaultAccountAndADottedServiceRoundTripByTheSectionNotTheTitle() throws {
        try put("guild-hub.mac-studio", "ci.2", secret: SecretValue(single: "x"))
        let back = try decodeVaultItem(try item("guild-hub.mac-studio", "ci.2").template())
        XCTAssertEqual(back.service, "guild-hub.mac-studio")
        XCTAssertEqual(back.account, "ci.2")
        XCTAssertEqual(back.title, "guild-hub.mac-studio.ci.2")
        try assertRoundTrip("guild-hub.mac-studio", "ci.2")
    }

    func testADescriptionWithNewlinesAndCJKIsTheNotesNotASectionField() throws {
        try put("cn", secret: SecretValue(fields: [("令牌", "值\n第二行"), ("k", "v")]), description: "部署用令牌\nsecond line: “quotes” & emoji 🔑")
        try assertRoundTrip("cn")
        let t = try item("cn").template()
        XCTAssertEqual(try fields(t).filter { $0["purpose"] as? String == "NOTES" }.map { $0["value"] as? String },
                       ["部署用令牌\nsecond line: “quotes” & emoji 🔑"])
        XCTAssertFalse(try fields(t).contains { $0["label"] as? String == "description" })
    }

    func testNoDescriptionRoundTripsAsNoneWithEmptyNotes() throws {
        try put("nodesc", secret: SecretValue(single: "x"))
        XCTAssertNil(try decodeVaultItem(try item("nodesc").template()).description)
        XCTAssertEqual(try fields(try item("nodesc").template()).filter { $0["purpose"] as? String == "NOTES" }.map { $0["value"] as? String }, [""])
    }

    /// The layout before ADR-0027 (optokens 0.1.7, mytokens-vault-5) kept the Description in the section: it is read
    /// from there when not empty, else from the notes, as optokens reads it; a rewrite over it moves it into the notes.
    func testThePreviousLayoutsSectionDescriptionIsReadAndMovedIntoTheNotes() throws {
        let previous = try fixture("0.1.7-put")
        XCTAssertEqual(try decodeVaultItem(previous).description, "CI deploy")
        var withNotes = try json(previous)
        withNotes["fields"] = (withNotes["fields"] as! [[String: Any]]) + [["id": "notesPlain", "purpose": "NOTES", "type": "STRING", "value": "typed"]]
        XCTAssertEqual(try decodeVaultItem(try JSONSerialization.data(withJSONObject: withNotes)).description, "CI deploy")
        var emptied = try json(previous)
        emptied["fields"] = (emptied["fields"] as! [[String: Any]]).map { f in
            var f = f; if f["label"] as? String == "description" { f["value"] = "" }; return f
        } + [["id": "notesPlain", "purpose": "NOTES", "type": "STRING", "value": "typed"]]
        XCTAssertEqual(try decodeVaultItem(try JSONSerialization.data(withJSONObject: emptied)).description, "typed")
        // made the sync's own in place: the same item optokens 0.1.8 writes for that Secret
        let decoded = try decodeVaultItem(previous)
        let retagged = try XCTUnwrap(vaultOwnTemplate(previous, digest: decoded.digest))
        var mine = try comparable(retagged) as! [String: Any]; mine["category"] = "SECURE_NOTE"
        XCTAssertEqual(mine as NSDictionary, try comparable(try fixture("put")))
        XCTAssertEqual(try comparable(decoded.template(over: previous)), try comparable(try fixture("put")))
    }

    func testAFieldNamedLikeTheMetadataStaysAField() throws {
        try put("app", secret: SecretValue(fields: [("kind", "FIELD"), ("service", "S")]), kind: "static")
        let back = try decodeVaultItem(try item("app").template())
        XCTAssertEqual(back.secret.value(forField: "kind"), "FIELD")
        XCTAssertEqual(back.kind, "static")
        XCTAssertEqual(back.service, "app")
    }

    // MARK: what the layout cannot hold

    func testAParentAndAListFieldAreUnwritableWithTheirFix() throws {
        try put("cloudflare", secret: SecretValue(single: "cf"), kind: "parent", meta: ["account_id": "a"])
        let list = try XCTUnwrap(ListValue.canonical(#"[{"host":"db1"}]"#))
        try put("db", "prod", secret: SecretValue(fields: [("Token", "t"), ("Hosts", list)], lists: ["Hosts"]))
        XCTAssertEqual(try item("cloudflare").unwritable?.fix, "mytokens put cloudflare --kind static")
        XCTAssertEqual(try item("db", "prod").unwritable?.fix, "mytokens put db --account prod --level personal")
        XCTAssertTrue(try item("db", "prod").unwritable?.why.contains("\"Hosts\" is a list") == true)
        try put("ok", secret: SecretValue(single: "v"))
        XCTAssertNil(try item("ok").unwritable)
    }

    func testWhatOptokensRefusesIsNotDecoded() throws {
        try put("a", secret: SecretValue(fields: [("k", "v")]))
        let good = try json(try item("a").template())
        func refused(_ edit: (inout [String: Any]) -> Void) -> String? {
            var i = good
            edit(&i)
            do { _ = try decodeVaultItem(try JSONSerialization.data(withJSONObject: i)); return nil } catch { return "\(error)" }
        }
        func editField(_ label: String, _ key: String, _ value: Any) -> (inout [String: Any]) -> Void {
            { i in i["fields"] = (i["fields"] as! [[String: Any]]).map { f in var f = f; if f["label"] as? String == label { f[key] = value }; return f } }
        }
        XCTAssertNil(refused { _ in })
        XCTAssertTrue(refused { $0["tags"] = ["mytokens"] }?.contains("no tag \"optokens\"") == true)
        XCTAssertTrue(refused(editField("kind", "value", "parent"))?.contains("neither static nor profile") == true)
        XCTAssertTrue(refused(editField("k", "type", "URL"))?.contains("neither CONCEALED nor STRING") == true)
        XCTAssertTrue(refused(editField("shape", "value", "bare"))?.contains("its shape is \"bare\"") == true)
        XCTAssertTrue(refused(editField("kind", "label", "level"))?.contains("has a field \"level\"") == true)
        XCTAssertTrue(refused { i in
            i["fields"] = (i["fields"] as! [[String: Any]]) + [["section": ["id": "optokens"], "type": "STRING", "label": "meta", "value": "[1]"]]
        }?.contains("meta is not a JSON object") == true)
    }

    func testTheOldLayoutIsNotOptokensAndAHandMadeItemReadsByLabel() throws {
        let old = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/op-item-profile.json"))
        XCTAssertFalse(isOptokensItem(old))
        XCTAssertThrowsError(try decodeVaultItem(old))
        XCTAssertTrue(isOptokensItem(try fixture("fields")))
        let foreign = try decodeForeignItem(try fixture("fields"), title: "anything")
        XCTAssertEqual(foreign.service, "fx-fields")
        XCTAssertEqual(foreign.account, "ci")
    }
}
