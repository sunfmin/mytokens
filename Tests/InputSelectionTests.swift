import XCTest

// How `put` reaches a human: the terminal when there is one, else the desktop
// popup, else the one-time tailnet link, else nothing — and then `put` stores
// nothing and prints what to run. Drives `SelectingSecretInput` through the
// `Dependencies` seam with fakes.
final class InputSelectionTests: XCTestCase {

    private func run(_ argv: [String], _ store: InMemorySecretStore, session: InputSession,
                     terminal: RecordingSecretInput, popup: RecordingSecretInput,
                     link: RecordingSecretInput = RecordingSecretInput(.unavailable),
                     role: HostRole = .personal) -> CommandResult {
        let input = SelectingSecretInput(session: session, role: role, terminal: terminal, popup: popup, link: link)
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

    func testTerminalAndPopupBothWinOverTheLink() {
        for session in [InputSession(hasTerminal: true, hasDesktop: false), InputSession(hasTerminal: false, hasDesktop: true)] {
            let link = RecordingSecretInput(.entered(["": "link-tok"]))
            let put = run(["put", "svc"], InMemorySecretStore(), session: session,
                          terminal: RecordingSecretInput(.entered(["": "t"])),
                          popup: RecordingSecretInput(.entered(["": "p"])), link: link)
            XCTAssertEqual(put.exitCode, 0)
            XCTAssertEqual(link.prompts.count, 0)
        }
    }

    func testNoTerminalNoDesktopUsesTheLink() {
        let store = InMemorySecretStore()
        let terminal = RecordingSecretInput(.entered(["Token": "x"]))
        let popup = RecordingSecretInput(.entered(["Token": "x"]))
        let link = RecordingSecretInput(.entered(["Token": "link-tok"]))
        let put = run(["put", "svc", "--fields", "Token", "--description", "CI deploy"], store,
                      session: InputSession(hasTerminal: false, hasDesktop: false),
                      terminal: terminal, popup: popup, link: link)
        XCTAssertEqual(put.exitCode, 0, put.stderr)
        XCTAssertEqual(terminal.prompts.count + popup.prompts.count, 0)
        XCTAssertEqual(link.prompts.first?.service, "svc")
        XCTAssertEqual(link.prompts.first?.description, "CI deploy")
        XCTAssertEqual(link.prompts.first?.fields.map(\.label), ["Token"])
        XCTAssertEqual(try store.get(service: "svc", account: "default")?.value(forField: "Token"), "link-tok")
    }

    func testOnAServerALoggedInDesktopIsSkippedForTheLink() {
        // A Server runs unattended: a popup there would wait on a screen nobody watches.
        let popup = RecordingSecretInput(.entered(["": "popup-tok"]))
        let link = RecordingSecretInput(.entered(["": "link-tok"]))
        let store = InMemorySecretStore()
        let put = run(["put", "svc"], store, session: InputSession(hasTerminal: false, hasDesktop: true),
                      terminal: RecordingSecretInput(.cancelled), popup: popup, link: link, role: .server)
        XCTAssertEqual(put.exitCode, 0, put.stderr)
        XCTAssertEqual(popup.prompts.count, 0)
        XCTAssertEqual(link.prompts.count, 1)
        XCTAssertEqual(try store.get(service: "svc", account: "default")?.loneValue, "link-tok")
    }

    func testOnAServerTheTerminalStillWins() {
        let terminal = RecordingSecretInput(.entered(["": "tty-tok"]))
        let link = RecordingSecretInput(.entered(["": "link-tok"]))
        let put = run(["put", "svc"], InMemorySecretStore(), session: InputSession(hasTerminal: true, hasDesktop: true),
                      terminal: terminal, popup: RecordingSecretInput(.cancelled), link: link, role: .server)
        XCTAssertEqual(put.exitCode, 0, put.stderr)
        XCTAssertEqual(terminal.prompts.count, 1)
        XCTAssertEqual(link.prompts.count, 0)
    }

    func testAnExpiredLinkStoresNothingAndFails() {
        let store = InMemorySecretStore()
        let put = run(["put", "svc", "--set", "A=b", "--fields", "Token"], store,
                      session: InputSession(hasTerminal: false, hasDesktop: false),
                      terminal: RecordingSecretInput(.cancelled), popup: RecordingSecretInput(.cancelled),
                      link: RecordingSecretInput(.expired))
        XCTAssertNotEqual(put.exitCode, 0)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(put.stderr.contains("expired"), put.stderr)
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
