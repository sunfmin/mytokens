import Foundation

// In-memory SecretStore for tests — never touches the real keychain.
final class InMemorySecretStore: SecretStore {
    struct Entry { var secret: SecretValue; var kind: String; var meta: Any?; var description: String?; var level: Level }
    private(set) var items: [String: Entry] = [:]
    var locked = false

    private func key(_ s: String, _ a: String) -> String { "\(s)\u{1}\(a)" }

    func upsert(service: String, account: String, secret: SecretValue, kind: String, meta: Any?, description: String?, level: Level) throws {
        if locked { throw StoreError.locked }
        items[key(service, account)] = Entry(secret: secret, kind: kind, meta: meta, description: description, level: level)
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
                level: e.level
            )
        }
    }

    /// Store an item as a build from before levels wrote it: its comment has no level,
    /// so it decodes through the real codec exactly as an old keychain item does.
    func putLegacy(service: String, account: String, secret: SecretValue, kind: String = "static") {
        let legacyComment = #"{"kind":"\#(kind)","meta":null}"#
        let level = CommentCodec.decode(legacyComment).level
        items[key(service, account)] = Entry(secret: secret, kind: kind, meta: nil, description: nil, level: level)
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
