import XCTest

// How `put` reaches a human: the terminal when there is one, else the desktop
// popup, else nothing — and then `put` stores nothing and prints what to run.
// Drives `SelectingSecretInput` through the `Dependencies` seam with fakes.
final class InputSelectionTests: XCTestCase {

    private func run(_ argv: [String], _ store: InMemorySecretStore, session: InputSession,
                     terminal: RecordingSecretInput, popup: RecordingSecretInput) -> CommandResult {
        let input = SelectingSecretInput(session: session, terminal: terminal, popup: popup)
        return runCommand(argv, Dependencies(store: store, input: input))
    }

    func testTerminalWinsWhenPresentEvenWithADesktop() {
        let store = InMemorySecretStore()
        let terminal = RecordingSecretInput(.entered(["Token": "tty-tok"]))
        let popup = RecordingSecretInput(.entered(["Token": "popup-tok"]))
        let put = run(["put", "svc", "--fields", "Token"], store,
                      session: InputSession(hasTerminal: true, hasDesktop: true), terminal: terminal, popup: popup)
        XCTAssertEqual(put.exitCode, 0)
        XCTAssertEqual(terminal.prompts.count, 1)
        XCTAssertEqual(popup.prompts.count, 0)
        XCTAssertEqual(runCommand(["get", "svc"], Dependencies(store: store, input: CannedSecretInput(value: nil))).stdout,
                       "tty-tok")
    }

    func testOverSSHWithoutDesktopTheTerminalReadsIt() {
        let store = InMemorySecretStore()
        let terminal = RecordingSecretInput(.entered(["": "ssh-tok"]))
        let popup = RecordingSecretInput(.cancelled)
        let put = run(["put", "svc", "--description", "CI deploy"], store,
                      session: InputSession(hasTerminal: true, hasDesktop: false), terminal: terminal, popup: popup)
        XCTAssertEqual(put.exitCode, 0)
        XCTAssertEqual(terminal.prompts.first?.service, "svc")
        XCTAssertEqual(terminal.prompts.first?.description, "CI deploy")   // shown before the first Field
        XCTAssertEqual(popup.prompts.count, 0)
        XCTAssertEqual(try store.get(service: "svc", account: "default")?.loneValue, "ssh-tok")
    }

    func testNoTerminalWithDesktopUsesThePopup() {
        let store = InMemorySecretStore()
        let terminal = RecordingSecretInput(.unavailable)
        let popup = RecordingSecretInput(.entered(["": "popup-tok"]))
        let put = run(["put", "svc"], store,
                      session: InputSession(hasTerminal: false, hasDesktop: true), terminal: terminal, popup: popup)
        XCTAssertEqual(put.exitCode, 0)
        XCTAssertEqual(terminal.prompts.count, 0)
        XCTAssertEqual(popup.prompts.count, 1)
        XCTAssertEqual(try store.get(service: "svc", account: "default")?.loneValue, "popup-tok")
    }

    func testNeitherFailsStoresNothingAndPrintsTheCommand() {
        let store = InMemorySecretStore()
        let terminal = RecordingSecretInput(.entered(["Access Key ID": "x"]))
        let popup = RecordingSecretInput(.entered(["Access Key ID": "x"]))
        let put = run(["put", "aws", "--set", "Region=eu-west-1", "--fields", "Access Key ID", "--description", "it's CI"],
                      store, session: InputSession(hasTerminal: false, hasDesktop: false), terminal: terminal, popup: popup)
        XCTAssertNotEqual(put.exitCode, 0)
        XCTAssertEqual(put.stdout, "")
        XCTAssertTrue(store.items.isEmpty)                         // the --set value isn't stored either
        XCTAssertEqual(terminal.prompts.count + popup.prompts.count, 0)
        // The exact command, quoted so it pastes verbatim.
        XCTAssertTrue(put.stderr.contains(
            #"mytokens put aws --set Region=eu-west-1 --fields 'Access Key ID' --description 'it'\''s CI'"#),
            put.stderr)
    }

    func testShowFieldsAreUnmaskedAndTheRestMasked() {
        let store = InMemorySecretStore()
        let terminal = RecordingSecretInput(.entered(["Access Key ID": "AKIA", "Secret Access Key": "s3cr3t"]))
        let put = run(["put", "aws", "--fields", "Access Key ID,Secret Access Key", "--show", "Access Key ID"], store,
                      session: InputSession(hasTerminal: true, hasDesktop: false),
                      terminal: terminal, popup: RecordingSecretInput(.cancelled))
        XCTAssertEqual(put.exitCode, 0)
        let fields = terminal.prompts.first?.fields ?? []
        XCTAssertEqual(fields.map(\.label), ["Access Key ID", "Secret Access Key"])
        XCTAssertEqual(fields.map(\.masked), [false, true])         // echo only for --show
    }

    func testUnavailableFromTheChosenInputAlsoFails() {
        // A terminal that vanished between probe and read: same failure, nothing stored.
        let store = InMemorySecretStore()
        let put = runCommand(["put", "svc"], Dependencies(store: store, input: CannedSecretInput(result: .unavailable)))
        XCTAssertNotEqual(put.exitCode, 0)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(put.stderr.contains("  mytokens put svc\n"), put.stderr)
    }
}
