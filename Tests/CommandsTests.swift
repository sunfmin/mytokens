import XCTest

// Scenario-based integration tests driving the single `Dependencies` seam.
// Asserts external behavior only: stdout, exit code, and resulting store state.
// No real keychain, no UI.
final class CommandsTests: XCTestCase {

    private func deps(_ store: InMemorySecretStore, input: String?) -> Dependencies {
        Dependencies(store: store, input: CannedSecretInput(value: input))
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
}
