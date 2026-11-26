import XCTest

// The real `op` check of the vault sync (mytokens#15): runs only through tools/op-real-check.sh
// (`make op-real-check`), which hands it the scratch service account's token in
// MYTOKENS_OP_REAL_CHECK_TOKEN after checking that token sees the vault mytokens-scratch alone.
// The store is in memory, never the keychain's Secrets; the vault is always `scratchVault`.
// Production vaults are never a test target. In the gate the variable is unset: it is skipped.
final class OnePasswordRealCheck: XCTestCase {
    static let tokenVariable = "MYTOKENS_OP_REAL_CHECK_TOKEN"

    func testTheSyncWritesReadsAndEmptiesTheScratchVault() throws {
        guard let token = ProcessInfo.processInfo.environment[Self.tokenVariable], !token.isEmpty else {
            throw XCTSkip("the real op check runs only through tools/op-real-check.sh")
        }
        let store = InMemorySecretStore()
        try store.upsert(service: onePasswordTokenService, account: "default", secret: SecretValue(single: token),
                         kind: "static", meta: nil, description: nil, level: .personal, marks: SyncMarks())
        let value = "real-check-\(UUID().uuidString)"
        // in optokens' layout (ADR-0024): every Field in the section `fields`
        try store.upsert(service: "op-real-check", account: "default",
                         secret: SecretValue(fields: [(label: "token", value: value), (label: "中文", value: "cjk-" + value),
                                                      (label: "Access Key ID", value: "key-" + value)]),
                         kind: "static", meta: nil, description: "written by tools/op-real-check.sh", level: .server, marks: SyncMarks())
        let cli = OPCommand()
        let memory = VaultMemoryRef()

        // Writes the item (a run that died midway left one behind: then it is updated).
        let wrote = try syncVault(scratchVault, store: store, cli: cli, memory: memory).get()
        XCTAssertTrue(wrote.contains("added op-real-check") || wrote.contains("updated op-real-check"), "\(wrote)")

        // A second sync 2 s later, before 1Password lists the new item: it writes nothing and makes no second item.
        Thread.sleep(forTimeInterval: 2)
        if wrote.contains("added op-real-check") {
            XCTAssertEqual(try syncVault(scratchVault, store: store, cli: cli, memory: memory).get(), ["no changes"])
        }

        // 1Password holds the value, as written.
        let read = try cli.run(["item", "get", "op-real-check", "--vault", scratchVault, "--fields", "label=token", "--reveal"],
                               stdin: Data(), token: token)
        XCTAssertEqual(read.exitCode, 0, read.stderr)
        XCTAssertEqual(read.stdout.trimmingCharacters(in: .whitespacesAndNewlines), value)

        // A Field is readable by `op read` at `fields/<Label>`, as optokens says, and what was written reads back.
        Thread.sleep(forTimeInterval: 10)
        for (reference, expected) in [("fields/token", value), ("fields/Access Key ID", "key-" + value)] {
            let r = try cli.run(["read", "op://\(scratchVault)/op-real-check/\(reference)"], stdin: Data(), token: token)
            XCTAssertEqual(r.exitCode, 0, "\(reference): \(r.stderr)")
            XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), expected, reference)
        }

        let item = try cli.run(["item", "get", "op-real-check", "--vault", scratchVault, "--format", "json", "--reveal"], stdin: Data(), token: token)
        let back = try decodeVaultItem(Data(item.stdout.utf8))
        XCTAssertEqual(back.secret.fields.map(\.value), [value, "cjk-" + value, "key-" + value])
        XCTAssertEqual(back.description, "written by tools/op-real-check.sh")

        // Nothing changed: nothing written.
        XCTAssertEqual(try syncVault(scratchVault, store: store, cli: cli, memory: memory).get(), ["no changes"])

        // Emptied: the item is archived.
        let emptied = try syncVault(scratchVault, store: store, cli: cli, holding: .nothing).get()
        XCTAssertTrue(emptied.contains("removed op-real-check"), "\(emptied)")
    }

    /// A conflict settled both ways (mytokens#16). "1Password changed" is another Mac's sync writing the item
    /// (a store of its own, no memory), which gives the item a new version as a hand edit does.
    func testAConflictIsSettledByKeepingEitherSide() throws {
        guard let token = ProcessInfo.processInfo.environment[Self.tokenVariable], !token.isEmpty else {
            throw XCTSkip("the real op check runs only through tools/op-real-check.sh")
        }
        let title = "op-real-keep"
        func storeWith(_ value: String, in store: InMemorySecretStore) throws {
            try store.upsert(service: title, account: "default", secret: SecretValue(fields: [(label: "token", value: value)]),
                             kind: "static", meta: nil, description: "written by tools/op-real-check.sh", level: .server, marks: SyncMarks())
        }
        let mac = InMemorySecretStore(), other = InMemorySecretStore()
        for s in [mac, other] {
            try s.upsert(service: onePasswordTokenService, account: "default", secret: SecretValue(single: token),
                         kind: "static", meta: nil, description: nil, level: .personal, marks: SyncMarks())
        }
        let cli = OPCommand()
        let memory = VaultMemoryRef()
        func sync(_ keep: VaultKeep? = nil) throws -> [String] {
            try syncVault(scratchVault, store: mac, cli: cli, memory: memory, keep: keep).get()
        }
        /// 1Password lists a write ~10 s later.
        func settle() { Thread.sleep(forTimeInterval: 12) }
        defer { _ = try? syncVault(scratchVault, store: InMemorySecretStore(), cli: cli, holding: .nothing).get() }

        try storeWith("start", in: mac)
        let wrote = try sync()
        XCTAssertTrue(wrote.contains("added \(title)") || wrote.contains("updated \(title)"), "\(wrote)")
        settle()
        XCTAssertEqual(try sync(), ["no changes"])

        for (side, kept) in [(VaultSide.mac, "kept this Mac's \(title) (written over 1Password's)"),
                             (.onePassword, "kept 1Password's \(title) (adopted over this Mac's)")] {
            let theirs = "vault-\(side.rawValue)", ours = "mac-\(side.rawValue)"
            try storeWith(theirs, in: other)
            XCTAssertEqual(try syncVault(scratchVault, store: other, cli: cli).get(), ["updated \(title)"])
            try storeWith(ours, in: mac)
            settle()
            let conflict = try sync()
            XCTAssertEqual(conflict.count, 1, "\(conflict)")
            XCTAssertTrue(conflict[0].hasPrefix("conflict \(title): changed in 1Password and on this Mac")
                          && conflict[0].hasSuffix("settle it: mytokens onepassword keep \(scratchVault) \(title) mac|1password"), conflict[0])
            XCTAssertEqual(try sync(VaultKeep(title: title, side: side)), [kept])
            let want = side == .mac ? ours : theirs
            XCTAssertEqual(try mac.get(service: title, account: "default")?.fields.first?.value, want)
            settle()
            XCTAssertEqual(try sync(), ["no changes"])
            let read = try cli.run(["item", "get", title, "--vault", scratchVault, "--fields", "label=token", "--reveal"],
                                   stdin: Data(), token: token)
            XCTAssertEqual(read.stdout.trimmingCharacters(in: .whitespacesAndNewlines), want, read.stderr)
        }
    }
}
