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
        app.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Store secret for \(service)/\(account)"
        alert.informativeText = "Paste or type the value. It is written straight to the Keychain and never shown."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "secret value"
        alert.accessoryView = field
        alert.addButton(withTitle: "Store")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}
