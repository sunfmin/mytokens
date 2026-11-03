import Foundation
import Security

/// What a prompt for secret Fields came back with.
enum PromptResult: Equatable {
    /// label → value for the requested fields (the bare case uses the empty label).
    case entered([String: String])
    /// The human cancelled (popup Cancel, or the terminal read failed).
    case cancelled
    /// This input has no way to reach a human here (no terminal, no desktop).
    case unavailable
}

/// Where a human can be reached from this process.
struct InputSession: Equatable {
    /// A controlling terminal (`/dev/tty` opens) — e.g. `ssh -t`, or Terminal.app.
    var hasTerminal: Bool
    /// A desktop (WindowServer) session the popup can appear in.
    var hasDesktop: Bool

    /// Probes the real process: opens `/dev/tty`, and asks the Security session
    /// whether it has graphic access (false over SSH, true under a logged-in GUI).
    static var current: InputSession {
        let fd = open("/dev/tty", O_RDWR | O_NOCTTY)
        if fd >= 0 { close(fd) }
        var attrs = SessionAttributeBits()
        var sid = SecuritySessionId()
        let graphic = SessionGetInfo(callerSecuritySession, &sid, &attrs) == errSecSuccess
            && attrs.contains(.sessionHasGraphicAccess)
        return InputSession(hasTerminal: fd >= 0, hasDesktop: graphic)
    }
}

/// The live `SecretInput`: picks how to reach the human for this run. The terminal
/// wins when there is one (works over SSH), else the desktop popup, else
/// `.unavailable` so `put` can say what to run instead. A later input path (e.g. a
/// one-time web link) joins here as another candidate.
struct SelectingSecretInput: SecretInput {
    var session: InputSession
    var terminal: SecretInput
    var popup: SecretInput

    func promptForSecret(service: String, account: String, description: String?, fields: [Field]) -> PromptResult {
        if session.hasTerminal {
            return terminal.promptForSecret(service: service, account: account, description: description, fields: fields)
        }
        if session.hasDesktop {
            return popup.promptForSecret(service: service, account: account, description: description, fields: fields)
        }
        return .unavailable
    }
}

/// Reads each Field from the controlling terminal with `readpassphrase(3)` and
/// `RPP_REQUIRE_TTY`: hidden unless the Field is unmasked (`--show`), and it reads
/// `/dev/tty`, so stdin/stdout may be pipes. Prints the Service and Description
/// first, as the popup does.
struct TerminalSecretInput: SecretInput {
    /// One line of input. The tty's canonical-mode line limit (1024 bytes on macOS)
    /// is the practical cap; the buffer is generous so it is never the limit.
    private static let bufferSize = 8192

    func promptForSecret(service: String, account: String, description: String?, fields: [Field]) -> PromptResult {
        let fd = open("/dev/tty", O_WRONLY | O_NOCTTY)
        guard fd >= 0 else { return .unavailable }
        var header = "mytokens: enter the secret for \(service) / \(account)\n"
        if let description, !description.isEmpty { header += "  \(description)\n" }
        _ = header.withCString { write(fd, $0, strlen($0)) }
        close(fd)

        var values: [String: String] = [:]
        var buf = [CChar](repeating: 0, count: Self.bufferSize)
        defer { _ = memset_s(&buf, buf.count, 0, buf.count) }   // don't leave the secret in memory
        for field in fields {
            let prompt = (field.label.isEmpty ? "Secret" : field.label) + ": "
            let flags = RPP_REQUIRE_TTY | (field.masked ? 0 : RPP_ECHO_ON)
            guard readpassphrase(prompt, &buf, buf.count, flags) != nil else { return .cancelled }
            values[field.label] = String(cString: buf)
        }
        return .entered(values)
    }
}
