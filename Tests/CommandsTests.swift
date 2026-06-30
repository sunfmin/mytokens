import XCTest

// Scenario-based integration tests driving the single `Dependencies` seam.
// Asserts external behavior only: stdout, exit code, and resulting store state.
// No real keychain, no UI.
final class CommandsTests: XCTestCase {

    private func deps(_ store: InMemorySecretStore, input: String?) -> Dependencies {
        Dependencies(store: store, input: CannedSecretInput(value: input))
    }

    private func mdeps(_ store: InMemorySecretStore, values: [String: String]?) -> Dependencies {
        Dependencies(store: store, input: CannedSecretInput(values: values))
    }

    func testAddThenGetRoundtrip() {
        let store = InMemorySecretStore()
        let add = runCommand(["add", "cloudflare"], deps(store, input: "tok-123"))
        XCTAssertEqual(add.exitCode, 0)

        let get = runCommand(["get", "cloudflare"], deps(store, input: nil))
        XCTAssertEqual(get.exitCode, 0)
        XCTAssertEqual(get.stdout, "tok-123")        // exact value, no trailing newline
        XCTAssertEqual(get.stderr, "")
    }

    func testGetAbsentIsNonZeroAndPrintsNothing() {
        let store = InMemorySecretStore()
        let get = runCommand(["get", "nope"], deps(store, input: nil))
        XCTAssertNotEqual(get.exitCode, 0)
        XCTAssertEqual(get.stdout, "")
    }

    func testListHidesValues() {
        let store = InMemorySecretStore()
        _ = runCommand(["add", "cloudflare", "--kind", "parent", "--meta", #"{"account_id":"acc1"}"#],
                       deps(store, input: "supersecretvalue"))
        let list = runCommand(["list"], deps(store, input: nil))
        XCTAssertEqual(list.exitCode, 0)
        XCTAssertTrue(list.stdout.contains("cloudflare/default"))
        XCTAssertTrue(list.stdout.contains("parent"))
        XCTAssertTrue(list.stdout.contains("account_id"))     // meta shown
        XCTAssertFalse(list.stdout.contains("supersecretvalue"))  // value never shown
    }

    func testRmThenGet() {
        let store = InMemorySecretStore()
        _ = runCommand(["add", "gh"], deps(store, input: "x"))
        XCTAssertEqual(runCommand(["rm", "gh"], deps(store, input: nil)).exitCode, 0)
        XCTAssertNotEqual(runCommand(["get", "gh"], deps(store, input: nil)).exitCode, 0)
    }

    func testReaddOverwrites() {
        let store = InMemorySecretStore()
        _ = runCommand(["add", "openai"], deps(store, input: "old"))
        _ = runCommand(["add", "openai"], deps(store, input: "new"))
        XCTAssertEqual(runCommand(["get", "openai"], deps(store, input: nil)).stdout, "new")
    }

    func testMultipleAccountsPerService() {
        let store = InMemorySecretStore()
        _ = runCommand(["add", "cloudflare", "--account", "personal"], deps(store, input: "p"))
        _ = runCommand(["add", "cloudflare", "--account", "work"], deps(store, input: "w"))
        XCTAssertEqual(runCommand(["get", "cloudflare", "--account", "personal"], deps(store, input: nil)).stdout, "p")
        XCTAssertEqual(runCommand(["get", "cloudflare", "--account", "work"], deps(store, input: nil)).stdout, "w")
    }

    func testCancelledPopupStoresNothing() {
        let store = InMemorySecretStore()
        let add = runCommand(["add", "cloudflare"], deps(store, input: nil))  // nil == cancelled
        XCTAssertNotEqual(add.exitCode, 0)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testInvalidMetaRejectedWithoutPrompting() {
        let store = InMemorySecretStore()
        let add = runCommand(["add", "cloudflare", "--meta", "not-json"], deps(store, input: "x"))
        XCTAssertNotEqual(add.exitCode, 0)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testLockedKeychainSurfacesDistinctError() {
        let store = InMemorySecretStore(); store.locked = true
        let add = runCommand(["add", "cloudflare"], deps(store, input: "x"))
        XCTAssertNotEqual(add.exitCode, 0)
        XCTAssertTrue(add.stderr.contains("locked"))
    }

    // ── Multi-field Secrets (ADR-0005) ─────────────────────────────────────────

    private let awsValues = ["Access Key ID": "AKIA123", "Secret Access Key": "sshhh"]

    func testMultiFieldAddGetByFieldAndJSON() {
        let store = InMemorySecretStore()
        let add = runCommand(["add", "aws", "--fields", "Access Key ID,Secret Access Key"],
                             mdeps(store, values: awsValues))
        XCTAssertEqual(add.exitCode, 0)

        // Each field is retrievable on its own as a raw value.
        XCTAssertEqual(runCommand(["get", "aws", "--field", "Secret Access Key"], mdeps(store, values: nil)).stdout, "sshhh")
        XCTAssertEqual(runCommand(["get", "aws", "--field", "Access Key ID"], mdeps(store, values: nil)).stdout, "AKIA123")

        // --json dumps the whole object.
        let json = runCommand(["get", "aws", "--json"], mdeps(store, values: nil))
        XCTAssertEqual(json.exitCode, 0)
        XCTAssertTrue(json.stdout.contains("AKIA123") && json.stdout.contains("sshhh"))
    }

    func testMultiFieldBareGetErrorsAndListsFields() {
        let store = InMemorySecretStore()
        _ = runCommand(["add", "aws", "--fields", "Access Key ID,Secret Access Key"], mdeps(store, values: awsValues))
        let bare = runCommand(["get", "aws"], mdeps(store, values: nil))
        XCTAssertNotEqual(bare.exitCode, 0)
        XCTAssertEqual(bare.stdout, "")                                  // never dumps a value by accident
        XCTAssertTrue(bare.stderr.contains("Access Key ID") && bare.stderr.contains("Secret Access Key"))
    }

    func testListShowsFieldLabelsNotValues() {
        let store = InMemorySecretStore()
        _ = runCommand(["add", "aws", "--fields", "Access Key ID,Secret Access Key"], mdeps(store, values: awsValues))
        let list = runCommand(["list"], mdeps(store, values: nil))
        XCTAssertTrue(list.stdout.contains("fields: Access Key ID, Secret Access Key"))
        XCTAssertFalse(list.stdout.contains("AKIA123"))
        XCTAssertFalse(list.stdout.contains("sshhh"))
    }

    func testGetUnknownFieldErrors() {
        let store = InMemorySecretStore()
        _ = runCommand(["add", "aws", "--fields", "Access Key ID,Secret Access Key"], mdeps(store, values: awsValues))
        let g = runCommand(["get", "aws", "--field", "Nope"], mdeps(store, values: nil))
        XCTAssertNotEqual(g.exitCode, 0)
        XCTAssertEqual(g.stdout, "")
    }

    func testGetFieldOnSingleSecretErrors() {
        let store = InMemorySecretStore()
        _ = runCommand(["add", "gh"], deps(store, input: "tok"))
        XCTAssertNotEqual(runCommand(["get", "gh", "--field", "whatever"], deps(store, input: nil)).exitCode, 0)
    }

    func testParentCannotCombineWithFields() {
        let store = InMemorySecretStore()
        let add = runCommand(["add", "aws", "--kind", "parent", "--fields", "a,b"], mdeps(store, values: ["a": "1", "b": "2"]))
        XCTAssertNotEqual(add.exitCode, 0)
        XCTAssertTrue(add.stderr.contains("parent"))
        XCTAssertTrue(store.items.isEmpty)
    }

    func testShowMustReferenceAField() {
        let store = InMemorySecretStore()
        let add = runCommand(["add", "aws", "--fields", "Access Key ID", "--show", "Nope"], mdeps(store, values: ["Access Key ID": "x"]))
        XCTAssertNotEqual(add.exitCode, 0)
        XCTAssertTrue(store.items.isEmpty)              // rejected before prompting
    }

    func testAnyEmptyFieldStoresNothing() {
        let store = InMemorySecretStore()
        let add = runCommand(["add", "aws", "--fields", "Access Key ID,Secret Access Key"],
                             mdeps(store, values: ["Access Key ID": "AKIA123", "Secret Access Key": ""]))
        XCTAssertNotEqual(add.exitCode, 0)
        XCTAssertTrue(store.items.isEmpty)              // all-or-nothing
    }
}
