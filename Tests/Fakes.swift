import Foundation

// In-memory SecretStore for tests — never touches the real keychain.
final class InMemorySecretStore: SecretStore {
    struct Entry { var value: String; var kind: String; var meta: Any? }
    private(set) var items: [String: Entry] = [:]
    var locked = false

    private func key(_ s: String, _ a: String) -> String { "\(s)\u{1}\(a)" }

    func upsert(service: String, account: String, value: String, kind: String, meta: Any?) throws {
        if locked { throw StoreError.locked }
        items[key(service, account)] = Entry(value: value, kind: kind, meta: meta)
    }

    func get(service: String, account: String) throws -> String? {
        if locked { throw StoreError.locked }
        return items[key(service, account)]?.value
    }

    func list() throws -> [SecretRecord] {
        if locked { throw StoreError.locked }
        return items.map { (k, e) in
            let parts = k.split(separator: "\u{1}", maxSplits: 1, omittingEmptySubsequences: false)
            return SecretRecord(
                service: String(parts[0]),
                account: parts.count > 1 ? String(parts[1]) : "",
                kind: e.kind,
                meta: e.meta.flatMap(JSONUtil.compact)
            )
        }
    }

    func delete(service: String, account: String) throws -> Bool {
        if locked { throw StoreError.locked }
        return items.removeValue(forKey: key(service, account)) != nil
    }
}

struct CannedSecretInput: SecretInput {
    var value: String?
    func promptForSecret(service: String, account: String) -> String? { value }
}
