import Foundation

// In-memory SecretStore for tests — never touches the real keychain.
final class InMemorySecretStore: SecretStore {
    struct Entry { var secret: SecretValue; var kind: String; var meta: Any?; var description: String?; var level: Level; var marks: SyncMarks }
    private(set) var items: [String: Entry] = [:]
    var locked = false

    private func key(_ s: String, _ a: String) -> String { "\(s)\u{1}\(a)" }

    func upsert(service: String, account: String, secret: SecretValue, kind: String, meta: Any?, description: String?, level: Level, marks: SyncMarks) throws {
        if locked { throw StoreError.locked }
        items[key(service, account)] = Entry(secret: secret, kind: kind, meta: meta, description: description, level: level, marks: marks)
    }

    func get(service: String, account: String) throws -> SecretValue? {
        if locked { throw StoreError.locked }
        return items[key(service, account)]?.secret
    }

    func list() throws -> [SecretRecord] {
        if locked { throw StoreError.locked }
        return items.map { (k, e) in
            let parts = k.split(separator: "\u{1}", maxSplits: 1, omittingEmptySubsequences: false)
            return SecretRecord(
                service: String(parts[0]),
                account: parts.count > 1 ? String(parts[1]) : "",
                kind: e.kind,
                meta: e.meta.flatMap(JSONUtil.compact),
                fields: e.secret.schema,
                description: e.description,
                level: e.level,
                pushed: e.marks.pushed,
                adopted: e.marks.adopted,
                origin: e.marks.origin,
                changed: e.marks.changed
            )
        }
    }

    /// Store an item as a build from before levels wrote it: its comment has no level,
    /// so it decodes through the real codec exactly as an old keychain item does.
    func putLegacy(service: String, account: String, secret: SecretValue, kind: String = "static") {
        let legacyComment = #"{"kind":"\#(kind)","meta":null}"#
        let decoded = CommentCodec.decode(legacyComment)
        items[key(service, account)] = Entry(secret: secret, kind: kind, meta: nil, description: nil,
                                             level: decoded.level, marks: decoded.marks)
    }

    func delete(service: String, account: String) throws -> Bool {
        if locked { throw StoreError.locked }
        return items.removeValue(forKey: key(service, account)) != nil
    }
}

struct CannedSecretInput: SecretInput {
    var result: PromptResult

    /// Single bare value, keyed by the empty-string label; nil == cancelled.
    init(value: String?) { self.result = value.map { .entered(["": $0]) } ?? .cancelled }
    /// Multi-field: label → value, exactly as the popup would return; nil == cancelled.
    init(values: [String: String]?) { self.result = values.map { .entered($0) } ?? .cancelled }
    /// Any outcome, e.g. `.unavailable` (no terminal, no desktop).
    init(result: PromptResult) { self.result = result }

    func promptForSecret(service: String, account: String, description: String?, fields: [Field]) -> PromptResult { result }
}

/// Records each prompt it receives, then answers with `result` — so a test can
/// tell which input `SelectingSecretInput` chose and what it was asked for.
final class RecordingSecretInput: SecretInput {
    let result: PromptResult
    private(set) var prompts: [(service: String, description: String?, fields: [Field])] = []
    init(_ result: PromptResult) { self.result = result }

    func promptForSecret(service: String, account: String, description: String?, fields: [Field]) -> PromptResult {
        prompts.append((service, description, fields))
        return result
    }
}

/// In-memory role setting: a Mac whose role is `role` until `host` sets it.
final class InMemoryHostRoleSetting: HostRoleSetting {
    var role: HostRole?           // nil == never set
    var unreadable = false        // simulate a setting the build can't read
    init(_ role: HostRole? = nil) { self.role = role }

    func read() throws -> HostRole {
        if unreadable { throw HostRoleError.unknown("bogus", path: "<fake>") }
        return role ?? .default
    }
    func write(_ role: HostRole) throws { self.role = role }
}

extension Dependencies {
    /// A personal Mac (the default role) whose one store is `store` — for tests
    /// that don't exercise the role.
    init(store: SecretStore, input: SecretInput) {
        self.init(role: InMemoryHostRoleSetting(), store: { _ in store }, input: { _ in input },
                  remote: RecordingRemote(), stdin: { Data() })
    }
}

/// Records each remote run — the host, the command and the stdin it was fed — and
/// answers with `respond`, which by default plays the Server's end of the pipe.
final class RecordingRemote: Remote {
    private(set) var runs: [(host: String, command: String, stdin: Data)] = []
    var respond: (_ command: String, _ stdin: Data) -> CommandResult
    init(respond: @escaping (_ command: String, _ stdin: Data) -> CommandResult = { _, _ in
        CommandResult(stdout: "", stderr: "", exitCode: 0)
    }) {
        self.respond = respond
    }
    func run(host: String, command: String, stdin: Data) throws -> CommandResult {
        runs.append((host, command, stdin))
        return respond(command, stdin)
    }
}

/// In-memory Server list: the item both personal Macs share, without a keychain.
final class InMemoryServerList: ServerList {
    var hosts: [String] = []
    var writes = 0
    func read() throws -> [String] { Array(Set(hosts)).sorted() }
    func write(_ hosts: [String]) throws { self.hosts = Array(Set(hosts)).sorted(); writes += 1 }
}
