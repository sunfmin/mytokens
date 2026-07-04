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

    // ── Description (ADR-0006) ──────────────────────────────────────────────────

    func testDescriptionShownInListButNotInGet() {
        let store = InMemorySecretStore()
        XCTAssertEqual(runCommand(["add", "gh", "--description", "CI release tagging"], deps(store, input: "tok")).exitCode, 0)

        let list = runCommand(["list"], deps(store, input: nil))
        XCTAssertTrue(list.stdout.contains("CI release tagging"))     // purpose visible in list
        XCTAssertFalse(list.stdout.contains("tok"))                   // value still hidden

        XCTAssertEqual(runCommand(["get", "gh"], deps(store, input: nil)).stdout, "tok")  // get unchanged
    }

    func testDescriptionAlongsideFields() {
        let store = InMemorySecretStore()
        _ = runCommand(["add", "aws", "--description", "CI deploy: S3 uploads", "--fields", "Access Key ID,Secret Access Key"],
                       mdeps(store, values: awsValues))
        let list = runCommand(["list"], mdeps(store, values: nil))
        XCTAssertTrue(list.stdout.contains("CI deploy: S3 uploads"))
        XCTAssertTrue(list.stdout.contains("fields: Access Key ID, Secret Access Key"))
        XCTAssertFalse(list.stdout.contains("AKIA123"))
    }

    // ── Profiles (ADR-0008) ─────────────────────────────────────────────────────

    private let glmValues = [
        "ANTHROPIC_BASE_URL": "https://open.bigmodel.cn/api/anthropic",
        "ANTHROPIC_AUTH_TOKEN": "glm-abc123",
        "ANTHROPIC_MODEL": "glm-4.6",
    ]

    func testProfileAddThenEnvEmitsExportLinesInOrder() {
        let store = InMemorySecretStore()
        let add = runCommand(["add", "glm", "--kind", "profile",
                              "--fields", "ANTHROPIC_BASE_URL,ANTHROPIC_AUTH_TOKEN,ANTHROPIC_MODEL"],
                             mdeps(store, values: glmValues))
        XCTAssertEqual(add.exitCode, 0)

        // Rendered as POSIX `export` lines, in the declared field order.
        let env = runCommand(["env", "glm"], mdeps(store, values: nil))
        XCTAssertEqual(env.exitCode, 0)
        XCTAssertEqual(env.stdout, """
        export ANTHROPIC_BASE_URL='https://open.bigmodel.cn/api/anthropic'
        export ANTHROPIC_AUTH_TOKEN='glm-abc123'
        export ANTHROPIC_MODEL='glm-4.6'

        """)
    }

    func testEnvOnSingleValueSecretErrors() {
        let store = InMemorySecretStore()
        _ = runCommand(["add", "gh"], deps(store, input: "tok"))
        let env = runCommand(["env", "gh"], deps(store, input: nil))
        XCTAssertNotEqual(env.exitCode, 0)
        XCTAssertEqual(env.stdout, "")                     // never dumps a value by accident
        XCTAssertTrue(env.stderr.contains("not a Profile"))
    }

    func testEnvOnParentSecretErrors() {
        let store = InMemorySecretStore()
        _ = runCommand(["add", "cloudflare", "--kind", "parent"], deps(store, input: "parent-tok"))
        let env = runCommand(["env", "cloudflare"], deps(store, input: nil))
        XCTAssertNotEqual(env.exitCode, 0)
        XCTAssertEqual(env.stdout, "")
    }

    func testEnvOnMultiFieldNonProfileErrors() {
        // A multi-field *credential* (kind static) must not render as env vars —
        // profile-ness is the kind marker, not the label shape.
        let store = InMemorySecretStore()
        _ = runCommand(["add", "aws", "--fields", "Access Key ID,Secret Access Key"], mdeps(store, values: awsValues))
        let env = runCommand(["env", "aws"], mdeps(store, values: nil))
        XCTAssertNotEqual(env.exitCode, 0)
        XCTAssertEqual(env.stdout, "")                     // no `export Access Key ID=…`
        XCTAssertFalse(env.stdout.contains("AKIA123"))
    }

    func testEnvOnAbsentServiceErrors() {
        let store = InMemorySecretStore()
        let env = runCommand(["env", "nope"], deps(store, input: nil))
        XCTAssertNotEqual(env.exitCode, 0)
        XCTAssertEqual(env.stdout, "")
    }

    func testEnvSingleQuotesValuesSafely() {
        // A value with a space, a single quote, and a command substitution must be
        // emitted so `eval` sets it verbatim and cannot inject shell.
        let store = InMemorySecretStore()
        _ = runCommand(["add", "weird", "--kind", "profile", "--fields", "TOKEN"],
                       mdeps(store, values: ["TOKEN": "a b'c$(x)"]))
        let env = runCommand(["env", "weird"], mdeps(store, values: nil))
        XCTAssertEqual(env.exitCode, 0)
        XCTAssertEqual(env.stdout, "export TOKEN='a b'\\''c$(x)'\n")
    }

    func testProfileWithoutFieldsErrors() {
        let store = InMemorySecretStore()
        let add = runCommand(["add", "glm", "--kind", "profile"], deps(store, input: "x"))
        XCTAssertNotEqual(add.exitCode, 0)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(add.stderr.contains("requires --fields"))
    }

    func testProfileInvalidEnvNameRejectedBeforePrompting() {
        let store = InMemorySecretStore()
        let add = runCommand(["add", "glm", "--kind", "profile", "--fields", "ANTHROPIC BASE URL"],
                             mdeps(store, values: ["ANTHROPIC BASE URL": "x"]))
        XCTAssertNotEqual(add.exitCode, 0)
        XCTAssertTrue(store.items.isEmpty)                 // rejected before prompting
        XCTAssertTrue(add.stderr.contains("valid environment-variable name"))
    }

    func testEnvSelectsAccount() {
        let store = InMemorySecretStore()
        _ = runCommand(["add", "glm", "--account", "work", "--kind", "profile", "--fields", "ANTHROPIC_MODEL"],
                       mdeps(store, values: ["ANTHROPIC_MODEL": "glm-4.6-work"]))
        _ = runCommand(["add", "glm", "--account", "personal", "--kind", "profile", "--fields", "ANTHROPIC_MODEL"],
                       mdeps(store, values: ["ANTHROPIC_MODEL": "glm-4.6-personal"]))
        let env = runCommand(["env", "glm", "--account", "work"], mdeps(store, values: nil))
        XCTAssertEqual(env.stdout, "export ANTHROPIC_MODEL='glm-4.6-work'\n")
    }

    func testListShowsProfileKindAndLabelsNotValues() {
        let store = InMemorySecretStore()
        _ = runCommand(["add", "glm", "--kind", "profile", "--description", "Claude Code to GLM",
                        "--fields", "ANTHROPIC_BASE_URL,ANTHROPIC_AUTH_TOKEN,ANTHROPIC_MODEL"],
                       mdeps(store, values: glmValues))
        let list = runCommand(["list"], mdeps(store, values: nil))
        XCTAssertTrue(list.stdout.contains("glm/default"))
        XCTAssertTrue(list.stdout.contains("profile"))
        XCTAssertTrue(list.stdout.contains("fields: ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_MODEL"))
        XCTAssertFalse(list.stdout.contains("glm-abc123"))   // token value never shown
    }
}
