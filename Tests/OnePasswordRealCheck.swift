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
        try store.upsert(service: "op-real-check", account: "default",
                         secret: SecretValue(fields: [(label: "token", value: value), (label: "Hosts", value: hosts)], lists: ["Hosts"]),
                         kind: "static", meta: nil, description: "written by tools/op-real-check.sh", level: .server, marks: SyncMarks())
        let cli = OPCommand()

        // Writes the item (a run that died midway left one behind: then it is updated).
        let wrote = try syncVault(scratchVault, store: store, cli: cli).get()
        XCTAssertTrue(wrote.contains("added op-real-check") || wrote.contains("updated op-real-check"), "\(wrote)")

        // 1Password holds the value, as written.
        let read = try cli.run(["item", "get", "op-real-check", "--vault", scratchVault, "--fields", "label=token", "--reveal"],
                               stdin: Data(), token: token)
        XCTAssertEqual(read.exitCode, 0, read.stderr)
        XCTAssertEqual(read.stdout.trimmingCharacters(in: .whitespacesAndNewlines), value)

        // Nothing changed: nothing written.
        XCTAssertEqual(try syncVault(scratchVault, store: store, cli: cli).get(), ["no changes"])

        // Emptied: the item is archived.
        let emptied = try syncVault(scratchVault, store: store, cli: cli, holding: .nothing).get()
        XCTAssertTrue(emptied.contains("removed op-real-check"), "\(emptied)")
    }
}
