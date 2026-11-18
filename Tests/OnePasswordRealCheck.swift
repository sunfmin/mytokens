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
        let hosts = try XCTUnwrap(ListValue.canonical(#"[{"host":"a","port":"22"},{"host":"b","port":"2222"}]"#))
        // labels `op://` cannot name: CJK, `[`/`:`, a space; and a list Field (mytokens#14)
        try store.upsert(service: "op-real-check", account: "default",
                         secret: SecretValue(fields: [(label: "token", value: value), (label: "中文", value: "cjk-" + value),
                                                      (label: "a[b]:c", value: "odd-" + value), (label: "Access Key ID", value: "key-" + value),
                                                      (label: "Hosts", value: hosts)], lists: ["Hosts"]),
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

        // Every Field and list record is readable by `op read`, by its id.
        Thread.sleep(forTimeInterval: 10)
        for (reference, expected) in [("token", value), ("__", "cjk-" + value), ("a_b__c", "odd-" + value),
                                      ("Access_Key_ID", "key-" + value), ("Hosts.1/host", "a"), ("Hosts.2/port", "2222")] {
            let r = try cli.run(["read", "op://\(scratchVault)/op-real-check/\(reference)"], stdin: Data(), token: token)
            XCTAssertEqual(r.exitCode, 0, "\(reference): \(r.stderr)")
            XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), expected, reference)
        }

        // Nothing changed: nothing written.
        XCTAssertEqual(try syncVault(scratchVault, store: store, cli: cli, memory: memory).get(), ["no changes"])

        // Emptied: the item is archived.
        let emptied = try syncVault(scratchVault, store: store, cli: cli, holding: .nothing).get()
        XCTAssertTrue(emptied.contains("removed op-real-check"), "\(emptied)")
    }
}
