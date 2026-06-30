import Foundation

// In-memory SecretStore for tests — never touches the real keychain.
final class InMemorySecretStore: SecretStore {
    struct Entry { var value: String; var kind: String; var meta: Any?; var fields: [String]?; var description: String? }
    private(set) var items: [String: Entry] = [:]
    var locked = false

    private func key(_ s: String, _ a: String) -> String { "\(s)\u{1}\(a)" }

    func upsert(service: String, account: String, value: String, kind: String, meta: Any?, fields: [String]?, description: String?) throws {
        if locked { throw StoreError.locked }
        items[key(service, account)] = Entry(value: value, kind: kind, meta: meta, fields: fields, description: description)
    }

    func get(service: String, account: String) throws -> StoredSecret? {
        if locked { throw StoreError.locked }
        return items[key(service, account)].map { StoredSecret(value: $0.value, fields: $0.fields) }
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
                fields: e.fields,
                description: e.description
            )
        }
    }

    func delete(service: String, account: String) throws -> Bool {
        if locked { throw StoreError.locked }
        return items.removeValue(forKey: key(service, account)) != nil
    }
}

struct CannedSecretInput: SecretInput {
    var values: [String: String]?   // nil == cancelled (Store not pressed)

    /// Single bare value, keyed by the empty-string label (today's add path).
    init(value: String?) { self.values = value.map { ["": $0] } }
    /// Multi-field: label → value, exactly as the popup would return.
    init(values: [String: String]?) { self.values = values }

    func promptForSecret(service: String, account: String, description: String?, fields: [Field]) -> [String: String]? { values }
}
