import Foundation

/// A Mac's role (ADR-0010): a `personal` Mac keeps its Secrets in the iCloud Keychain; a
/// `server` does not sign into iCloud and keeps them in its own login keychain, readable
/// while its screen is locked — an unattended server's normal state. Every Secret stored
/// on a server is `server`-level.
enum HostRole: String, CaseIterable {
    case personal, server

    static let `default`: HostRole = .personal

    /// The allowed values as the CLI spells them, for error messages.
    static var allowed: String { allCases.map { "'\($0.rawValue)'" }.joined(separator: " or ") }

    /// Whether someone sits at this Mac. A Server runs unattended (ADR-0010), so `put`
    /// never shows its popup there — it would wait on a screen nobody watches.
    var isAttended: Bool { self == .personal }

    /// Where this role's Secrets live — the one place the role picks a store.
    var keychain: KeychainLocation {
        switch self {
        case .personal: return .iCloud
        case .server: return .login
        }
    }
}

/// The Mac's one local role setting (`mytokens host`). Tests use an in-memory fake.
protocol HostRoleSetting {
    func read() throws -> HostRole      // the default when never set
    func write(_ role: HostRole) throws
}

enum HostRoleError: Error, CustomStringConvertible {
    case unknown(String, path: String)

    var description: String {
        switch self {
        case .unknown(let raw, let path):
            return "unknown host role '\(raw)' in \(path) — set it with `mytokens host \(HostRole.allCases.map(\.rawValue).joined(separator: "|"))`"
        }
    }
}

/// Real setting: one small file, `~/Library/Application Support/mytokens/host-role`,
/// holding `personal` or `server`. Absent ⇒ `personal`. A file the build can't read as
/// a role is an error, never a silent default: a server must not quietly act on the
/// iCloud Keychain.
struct FileHostRoleSetting: HostRoleSetting {
    var url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/mytokens/host-role")

    func read() throws -> HostRole {
        guard let data = FileManager.default.contents(atPath: url.path) else { return .default }
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let role = HostRole(rawValue: raw) else { throw HostRoleError.unknown(raw, path: url.path) }
        return role
    }

    func write(_ role: HostRole) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((role.rawValue + "\n").utf8).write(to: url, options: .atomic)
    }
}
