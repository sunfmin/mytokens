import Foundation
import AppKit

/// One field to prompt for: a display label and whether its input is masked
/// (ADR-0005). An empty label is the single bare-secret case (today's look).
struct Field {
    let label: String
    let masked: Bool
}

/// How `add` collects a secret. The real impl pops native fields; tests inject
/// canned values. `description` is the agent's purpose note shown to the human
/// (ADR-0006). Returns label → value for the given fields (the single bare case
/// uses the empty-string label), or nil if cancelled. Values are returned only
/// to the Helper process — never to the caller's shell.
protocol SecretInput {
    func promptForSecret(service: String, account: String, description: String?, fields: [Field]) -> [String: String]?
}

/// Native masked popup. Builds `SecretPromptView`, hosts it in a modal window,
/// and runs it on the main thread; the process exits right after, so the
/// temporary GUI activation is harmless. The view-building lives in
/// `SecretPromptView` so the render test exercises the exact same UI.
struct PopupSecretInput: SecretInput {
    func promptForSecret(service: String, account: String, description: String?, fields: [Field]) -> [String: String]? {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        installEditMenu(app)   // wire up ⌘X/⌘C/⌘V/⌘A so paste works in the field

        let card = SecretPromptView.make(service: service, account: account, description: description, fields: fields)

        // A titled, chrome-free window: the card supplies all the visuals, and a
        // real titled window (unlike a borderless one) can become key so the
        // secure field accepts typing and paste.
        let window = NSWindow(contentRect: card.bounds,
                              styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.contentView = card
        window.level = .floating

        // Buttons end the modal session; map their codes back to Store / Cancel.
        let ender = ModalEnder()
        card.storeButton.target = ender
        card.storeButton.action = #selector(ModalEnder.store)
        card.cancelButton.target = ender
        card.cancelButton.action = #selector(ModalEnder.cancel)

        // CLI-launched apps aren't frontmost; force the window up and focused.
        window.initialFirstResponder = card.firstField
        app.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        let response = app.runModal(for: window)
        window.orderOut(nil)
        guard response == .OK else { return nil }
        return card.values
    }

    /// A minimal Edit menu so standard editing key-equivalents reach the field
    /// editor via the responder chain (nil target). Without it, ⌘V is dead.
    private func installEditMenu(_ app: NSApplication) {
        let mainMenu = NSMenu()
        let editHolder = NSMenuItem()
        mainMenu.addItem(editHolder)
        let editMenu = NSMenu(title: "Edit")
        editHolder.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        app.mainMenu = mainMenu
    }
}

/// Tiny target the dialog's buttons message to end the modal session. Kept alive
/// by the local reference in `promptForSecret` for the duration of the run loop.
private final class ModalEnder: NSObject {
    @objc func store()  { NSApp.stopModal(withCode: .OK) }
    @objc func cancel() { NSApp.stopModal(withCode: .cancel) }
}
