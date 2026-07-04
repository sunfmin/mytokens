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
        let add = runCommand(["put", "cloudflare"], deps(store, input: "tok-123"))
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
        _ = runCommand(["put", "cloudflare", "--kind", "parent", "--meta", #"{"account_id":"acc1"}"#],
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
        _ = runCommand(["put", "gh"], deps(store, input: "x"))
        XCTAssertEqual(runCommand(["rm", "gh"], deps(store, input: nil)).exitCode, 0)
        XCTAssertNotEqual(runCommand(["get", "gh"], deps(store, input: nil)).exitCode, 0)
    }

    func testReaddOverwrites() {
        let store = InMemorySecretStore()
        _ = runCommand(["put", "openai"], deps(store, input: "old"))
        _ = runCommand(["put", "openai"], deps(store, input: "new"))
        XCTAssertEqual(runCommand(["get", "openai"], deps(store, input: nil)).stdout, "new")
    }

    func testMultipleAccountsPerService() {
        let store = InMemorySecretStore()
        _ = runCommand(["put", "cloudflare", "--account", "personal"], deps(store, input: "p"))
        _ = runCommand(["put", "cloudflare", "--account", "work"], deps(store, input: "w"))
        XCTAssertEqual(runCommand(["get", "cloudflare", "--account", "personal"], deps(store, input: nil)).stdout, "p")
        XCTAssertEqual(runCommand(["get", "cloudflare", "--account", "work"], deps(store, input: nil)).stdout, "w")
    }

    func testCancelledPopupStoresNothing() {
        let store = InMemorySecretStore()
        let add = runCommand(["put", "cloudflare"], deps(store, input: nil))  // nil == cancelled
        XCTAssertNotEqual(add.exitCode, 0)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testInvalidMetaRejectedWithoutPrompting() {
        let store = InMemorySecretStore()
        let add = runCommand(["put", "cloudflare", "--meta", "not-json"], deps(store, input: "x"))
        XCTAssertNotEqual(add.exitCode, 0)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testLockedKeychainSurfacesDistinctError() {
        let store = InMemorySecretStore(); store.locked = true
        let add = runCommand(["put", "cloudflare"], deps(store, input: "x"))
        XCTAssertNotEqual(add.exitCode, 0)
        XCTAssertTrue(add.stderr.contains("locked"))
    }

    // ── Multi-field Secrets (ADR-0005) ─────────────────────────────────────────

    private let awsValues = ["Access Key ID": "AKIA123", "Secret Access Key": "sshhh"]

    func testMultiFieldAddGetByFieldAndJSON() {
        let store = InMemorySecretStore()
        let add = runCommand(["put", "aws", "--fields", "Access Key ID,Secret Access Key"],
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
        _ = runCommand(["put", "aws", "--fields", "Access Key ID,Secret Access Key"], mdeps(store, values: awsValues))
        let bare = runCommand(["get", "aws"], mdeps(store, values: nil))
        XCTAssertNotEqual(bare.exitCode, 0)
        XCTAssertEqual(bare.stdout, "")                                  // never dumps a value by accident
        XCTAssertTrue(bare.stderr.contains("Access Key ID") && bare.stderr.contains("Secret Access Key"))
    }

    func testListShowsFieldLabelsNotValues() {
        let store = InMemorySecretStore()
        _ = runCommand(["put", "aws", "--fields", "Access Key ID,Secret Access Key"], mdeps(store, values: awsValues))
        let list = runCommand(["list"], mdeps(store, values: nil))
        XCTAssertTrue(list.stdout.contains("fields: Access Key ID, Secret Access Key"))
        XCTAssertFalse(list.stdout.contains("AKIA123"))
        XCTAssertFalse(list.stdout.contains("sshhh"))
    }

    func testGetUnknownFieldErrors() {
        let store = InMemorySecretStore()
        _ = runCommand(["put", "aws", "--fields", "Access Key ID,Secret Access Key"], mdeps(store, values: awsValues))
        let g = runCommand(["get", "aws", "--field", "Nope"], mdeps(store, values: nil))
        XCTAssertNotEqual(g.exitCode, 0)
        XCTAssertEqual(g.stdout, "")
    }

    func testGetFieldOnSingleSecretErrors() {
        let store = InMemorySecretStore()
        _ = runCommand(["put", "gh"], deps(store, input: "tok"))
        XCTAssertNotEqual(runCommand(["get", "gh", "--field", "whatever"], deps(store, input: nil)).exitCode, 0)
    }

    func testParentCannotCombineWithFields() {
        let store = InMemorySecretStore()
        let add = runCommand(["put", "aws", "--kind", "parent", "--fields", "a,b"], mdeps(store, values: ["a": "1", "b": "2"]))
        XCTAssertNotEqual(add.exitCode, 0)
        XCTAssertTrue(add.stderr.contains("parent"))
        XCTAssertTrue(store.items.isEmpty)
    }

    func testShowMustReferenceAField() {
        let store = InMemorySecretStore()
        let add = runCommand(["put", "aws", "--fields", "Access Key ID", "--show", "Nope"], mdeps(store, values: ["Access Key ID": "x"]))
        XCTAssertNotEqual(add.exitCode, 0)
        XCTAssertTrue(store.items.isEmpty)              // rejected before prompting
    }

    func testAnyEmptyFieldStoresNothing() {
        let store = InMemorySecretStore()
        let add = runCommand(["put", "aws", "--fields", "Access Key ID,Secret Access Key"],
                             mdeps(store, values: ["Access Key ID": "AKIA123", "Secret Access Key": ""]))
        XCTAssertNotEqual(add.exitCode, 0)
        XCTAssertTrue(store.items.isEmpty)              // all-or-nothing
    }

    // ── Description (ADR-0006) ──────────────────────────────────────────────────

    func testDescriptionShownInListButNotInGet() {
        let store = InMemorySecretStore()
        XCTAssertEqual(runCommand(["put", "gh", "--description", "CI release tagging"], deps(store, input: "tok")).exitCode, 0)

        let list = runCommand(["list"], deps(store, input: nil))
        XCTAssertTrue(list.stdout.contains("CI release tagging"))     // purpose visible in list
        XCTAssertFalse(list.stdout.contains("tok"))                   // value still hidden

        XCTAssertEqual(runCommand(["get", "gh"], deps(store, input: nil)).stdout, "tok")  // get unchanged
    }

    func testDescriptionAlongsideFields() {
        let store = InMemorySecretStore()
        _ = runCommand(["put", "aws", "--description", "CI deploy: S3 uploads", "--fields", "Access Key ID,Secret Access Key"],
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
        let add = runCommand(["put", "glm", "--kind", "profile",
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
        _ = runCommand(["put", "gh"], deps(store, input: "tok"))
        let env = runCommand(["env", "gh"], deps(store, input: nil))
        XCTAssertNotEqual(env.exitCode, 0)
        XCTAssertEqual(env.stdout, "")                     // never dumps a value by accident
        XCTAssertTrue(env.stderr.contains("not a Profile"))
    }

    func testEnvOnParentSecretErrors() {
        let store = InMemorySecretStore()
        _ = runCommand(["put", "cloudflare", "--kind", "parent"], deps(store, input: "parent-tok"))
        let env = runCommand(["env", "cloudflare"], deps(store, input: nil))
        XCTAssertNotEqual(env.exitCode, 0)
        XCTAssertEqual(env.stdout, "")
    }

    func testEnvOnMultiFieldNonProfileErrors() {
        // A multi-field *credential* (kind static) must not render as env vars —
        // profile-ness is the kind marker, not the label shape.
        let store = InMemorySecretStore()
        _ = runCommand(["put", "aws", "--fields", "Access Key ID,Secret Access Key"], mdeps(store, values: awsValues))
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
        _ = runCommand(["put", "weird", "--kind", "profile", "--fields", "TOKEN"],
                       mdeps(store, values: ["TOKEN": "a b'c$(x)"]))
        let env = runCommand(["env", "weird"], mdeps(store, values: nil))
        XCTAssertEqual(env.exitCode, 0)
        XCTAssertEqual(env.stdout, "export TOKEN='a b'\\''c$(x)'\n")
    }

    func testProfileWithoutFieldsErrors() {
        let store = InMemorySecretStore()
        let add = runCommand(["put", "glm", "--kind", "profile"], deps(store, input: "x"))
        XCTAssertNotEqual(add.exitCode, 0)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(add.stderr.contains("requires --set or --fields"))
    }

    func testProfileInvalidEnvNameRejectedBeforePrompting() {
        let store = InMemorySecretStore()
        let add = runCommand(["put", "glm", "--kind", "profile", "--fields", "ANTHROPIC BASE URL"],
                             mdeps(store, values: ["ANTHROPIC BASE URL": "x"]))
        XCTAssertNotEqual(add.exitCode, 0)
        XCTAssertTrue(store.items.isEmpty)                 // rejected before prompting
        XCTAssertTrue(add.stderr.contains("valid environment-variable name"))
    }

    func testEnvSelectsAccount() {
        let store = InMemorySecretStore()
        _ = runCommand(["put", "glm", "--account", "work", "--kind", "profile", "--fields", "ANTHROPIC_MODEL"],
                       mdeps(store, values: ["ANTHROPIC_MODEL": "glm-4.6-work"]))
        _ = runCommand(["put", "glm", "--account", "personal", "--kind", "profile", "--fields", "ANTHROPIC_MODEL"],
                       mdeps(store, values: ["ANTHROPIC_MODEL": "glm-4.6-personal"]))
        let env = runCommand(["env", "glm", "--account", "work"], mdeps(store, values: nil))
        XCTAssertEqual(env.stdout, "export ANTHROPIC_MODEL='glm-4.6-work'\n")
    }

    func testListShowsProfileKindAndLabelsNotValues() {
        let store = InMemorySecretStore()
        _ = runCommand(["put", "glm", "--kind", "profile", "--description", "Claude Code to GLM",
                        "--fields", "ANTHROPIC_BASE_URL,ANTHROPIC_AUTH_TOKEN,ANTHROPIC_MODEL"],
                       mdeps(store, values: glmValues))
        let list = runCommand(["list"], mdeps(store, values: nil))
        XCTAssertTrue(list.stdout.contains("glm/default"))
        XCTAssertTrue(list.stdout.contains("profile"))
        XCTAssertTrue(list.stdout.contains("fields: ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_MODEL"))
        XCTAssertFalse(list.stdout.contains("glm-abc123"))   // token value never shown
    }

    // ── put: --set from the CLI + field-level merge (ADR-0009) ──────────────────

    func testPutSetCreatesFromCLIWithNoPopup() {
        let store = InMemorySecretStore()
        // No popup: the values come from --set, so the canned input is never consulted.
        let put = runCommand(["put", "longcat", "--kind", "profile",
                              "--set", "ANTHROPIC_BASE_URL=https://api.longcat.chat/anthropic",
                              "--set", "ANTHROPIC_MODEL=LongCat-2.0"],
                             mdeps(store, values: nil))
        XCTAssertEqual(put.exitCode, 0)
        let env = runCommand(["env", "longcat"], mdeps(store, values: nil))
        XCTAssertEqual(env.stdout, """
        export ANTHROPIC_BASE_URL='https://api.longcat.chat/anthropic'
        export ANTHROPIC_MODEL='LongCat-2.0'

        """)
    }

    func testPutSetUpdatesOneFieldKeepingOthers() {
        let store = InMemorySecretStore()
        _ = runCommand(["put", "longcat", "--kind", "profile",
                        "--set", "ANTHROPIC_BASE_URL=https://api.longcat.chat/anthropic",
                        "--set", "ANTHROPIC_MODEL=LongCat-2.0"], mdeps(store, values: nil))
        let upd = runCommand(["put", "longcat", "--set", "ANTHROPIC_MODEL=LongCat-3.0"], mdeps(store, values: nil))
        XCTAssertEqual(upd.exitCode, 0)
        let env = runCommand(["env", "longcat"], mdeps(store, values: nil))
        XCTAssertEqual(env.stdout, """
        export ANTHROPIC_BASE_URL='https://api.longcat.chat/anthropic'
        export ANTHROPIC_MODEL='LongCat-3.0'

        """)   // BASE_URL untouched, MODEL updated in place, order preserved
    }

    func testPutFieldsRotatesSecretKeepingConfig() {
        let store = InMemorySecretStore()
        _ = runCommand(["put", "longcat", "--kind", "profile",
                        "--set", "ANTHROPIC_BASE_URL=https://api.longcat.chat/anthropic",
                        "--set", "ANTHROPIC_MODEL=LongCat-2.0",
                        "--fields", "ANTHROPIC_AUTH_TOKEN"],
                       mdeps(store, values: ["ANTHROPIC_AUTH_TOKEN": "ak_old"]))
        // Rotate only the token via the popup; the two config fields are untouched.
        let rot = runCommand(["put", "longcat", "--fields", "ANTHROPIC_AUTH_TOKEN"],
                             mdeps(store, values: ["ANTHROPIC_AUTH_TOKEN": "ak_new"]))
        XCTAssertEqual(rot.exitCode, 0)
        XCTAssertEqual(runCommand(["get", "longcat", "--field", "ANTHROPIC_AUTH_TOKEN"], mdeps(store, values: nil)).stdout, "ak_new")
        XCTAssertEqual(runCommand(["get", "longcat", "--field", "ANTHROPIC_MODEL"], mdeps(store, values: nil)).stdout, "LongCat-2.0")
        XCTAssertEqual(runCommand(["get", "longcat", "--field", "ANTHROPIC_BASE_URL"], mdeps(store, values: nil)).stdout, "https://api.longcat.chat/anthropic")
    }

    func testPutUpdatesOneCredentialFieldKeepingOther() {
        // Composite credentials are independently updatable too (ADR-0009 relaxes ADR-0005),
        // and env-name validation does NOT apply to a non-Profile — the space in the label is fine.
        let store = InMemorySecretStore()
        _ = runCommand(["put", "aws", "--fields", "Access Key ID,Secret Access Key"],
                       mdeps(store, values: ["Access Key ID": "AKIA1", "Secret Access Key": "s1"]))
        _ = runCommand(["put", "aws", "--fields", "Secret Access Key"],
                       mdeps(store, values: ["Secret Access Key": "s2"]))
        XCTAssertEqual(runCommand(["get", "aws", "--field", "Access Key ID"], mdeps(store, values: nil)).stdout, "AKIA1")   // untouched
        XCTAssertEqual(runCommand(["get", "aws", "--field", "Secret Access Key"], mdeps(store, values: nil)).stdout, "s2")
    }

    func testPutSetOnSingleValueSecretErrors() {
        let store = InMemorySecretStore()
        _ = runCommand(["put", "gh"], deps(store, input: "tok"))            // bare single value
        let bad = runCommand(["put", "gh", "--set", "FOO=bar"], mdeps(store, values: nil))
        XCTAssertNotEqual(bad.exitCode, 0)
        XCTAssertTrue(bad.stderr.contains("single-value"))
        XCTAssertEqual(runCommand(["get", "gh"], deps(store, input: nil)).stdout, "tok")   // unchanged
    }

    func testPutBareOnLabelledSecretErrors() {
        let store = InMemorySecretStore()
        _ = runCommand(["put", "aws", "--fields", "Access Key ID,Secret Access Key"], mdeps(store, values: awsValues))
        let bad = runCommand(["put", "aws"], deps(store, input: "whatever"))   // bare put onto a multi-field secret
        XCTAssertNotEqual(bad.exitCode, 0)
        XCTAssertTrue(bad.stderr.contains("named fields"))
    }

    func testPutSetSplitsOnFirstEquals() {
        let store = InMemorySecretStore()
        _ = runCommand(["put", "x", "--kind", "profile", "--set", "TOKEN=a=b=c"], mdeps(store, values: nil))
        XCTAssertEqual(runCommand(["get", "x", "--field", "TOKEN"], mdeps(store, values: nil)).stdout, "a=b=c")
    }

    func testPutSetRejectsEmptyValue() {
        let store = InMemorySecretStore()
        let bad = runCommand(["put", "x", "--kind", "profile", "--set", "TOKEN="], mdeps(store, values: nil))
        XCTAssertNotEqual(bad.exitCode, 0)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testRmThenPutReplacesWhole() {
        let store = InMemorySecretStore()
        _ = runCommand(["put", "longcat", "--kind", "profile",
                        "--set", "A=1", "--set", "B=2", "--set", "C=3"], mdeps(store, values: nil))
        _ = runCommand(["rm", "longcat"], mdeps(store, values: nil))
        _ = runCommand(["put", "longcat", "--kind", "profile", "--set", "A=9"], mdeps(store, values: nil))
        let env = runCommand(["env", "longcat"], mdeps(store, values: nil))
        XCTAssertEqual(env.stdout, "export A='9'\n")   // B and C are gone — whole-replace via rm+put
    }

    func testPutMergePreservesKindAndDescription() {
        let store = InMemorySecretStore()
        _ = runCommand(["put", "longcat", "--kind", "profile", "--description", "Claude Code to LongCat",
                        "--set", "ANTHROPIC_MODEL=LongCat-2.0"], mdeps(store, values: nil))
        // A --set update with no --kind/--description keeps both.
        _ = runCommand(["put", "longcat", "--set", "ANTHROPIC_MODEL=LongCat-3.0"], mdeps(store, values: nil))
        let list = runCommand(["list"], mdeps(store, values: nil))
        XCTAssertTrue(list.stdout.contains("profile"))
        XCTAssertTrue(list.stdout.contains("Claude Code to LongCat"))
    }

    func testPutCannotChangeKindOnMerge() {
        let store = InMemorySecretStore()
        _ = runCommand(["put", "longcat", "--kind", "profile", "--set", "ANTHROPIC_MODEL=LongCat-2.0"], mdeps(store, values: nil))
        let bad = runCommand(["put", "longcat", "--kind", "static", "--set", "ANTHROPIC_MODEL=LongCat-3.0"], mdeps(store, values: nil))
        XCTAssertNotEqual(bad.exitCode, 0)
        XCTAssertTrue(bad.stderr.contains("rm it first to change kind"))
    }
}
