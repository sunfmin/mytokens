import Foundation
import AppKit

/// How `add` collects a secret value. The real impl pops a native secure field;
/// tests inject a canned value. The value is returned only to the Helper process
/// — never to the caller's shell.
protocol SecretInput {
    func promptForSecret(service: String, account: String) -> String?  // nil if cancelled
}

/// Native masked popup. Runs modally on the main thread; the process exits
/// right after, so the temporary GUI activation is harmless.
struct PopupSecretInput: SecretInput {
    func promptForSecret(service: String, account: String) -> String? {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        installEditMenu(app)   // wire up ⌘X/⌘C/⌘V/⌘A so paste works in the field

        let alert = NSAlert()
        alert.messageText = "Store secret for \(service)/\(account)"
        alert.informativeText = "Paste or type the value. It is written straight to the Keychain and never shown."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "secret value"
        alert.accessoryView = field
        alert.addButton(withTitle: "Store")
        alert.addButton(withTitle: "Cancel")

        // CLI-launched apps aren't frontmost; force the window up and focused.
        let window = alert.window
        window.initialFirstResponder = field
        window.level = .floating
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue
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
