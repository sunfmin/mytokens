import Foundation
import Security

// The non-secret view of a stored item (no value) — used by `list`.
struct SecretRecord {
    var service: String
    var account: String
    var kind: String          // "static" | "parent"
    var meta: String?         // compact JSON, or nil
    var fields: [String]?     // ordered field labels for a multi-field Secret, else nil
    var description: String?  // agent-authored purpose note (ADR-0006), or nil
}

// What `get` reads back: the stored value plus, for a multi-field Secret, its
// ordered field schema. `value` is the raw secret for a single-field Secret, or a
// compact JSON object {label: value} for a multi-field one (ADR-0005).
struct StoredSecret {
    var value: String
    var fields: [String]?   // nil for a single bare-value Secret
}

enum StoreError: Error, CustomStringConvertible {
    case keychain(OSStatus)
    case locked
    case encoding

    var description: String {
        switch self {
        case .keychain(let s):
            let m = SecCopyErrorMessageString(s, nil).map { $0 as String } ?? "unknown"
            return "keychain error \(s): \(m)"
        case .locked:
            return "keychain is locked (interaction not allowed) — unlock the login session and retry"
        case .encoding:
            return "failed to encode/decode item metadata"
        }
    }
}

/// The lowest-level seam for stored Secrets. The real impl talks to the
/// data-protection (iCloud) keychain; tests use an in-memory fake.
protocol SecretStore {
    func upsert(service: String, account: String, value: String, kind: String, meta: Any?, fields: [String]?, description: String?) throws
    func get(service: String, account: String) throws -> StoredSecret?   // nil if absent
    func list() throws -> [SecretRecord]
    func delete(service: String, account: String) throws -> Bool   // false if absent
}

// Must match the `keychain-access-groups` entitlement (= application-identifier).
// macOS does NOT isolate data-protection queries by group for non-sandboxed apps,
// so every query is scoped to this group explicitly to avoid touching other apps' items.
private let mytokensAccessGroup = "HL27PWAKDF.com.sunfmin.mytokens"
private let mytokensLabelPrefix = "mytokens: "

/// Real store: synchronizable generic-password items in the data-protection
/// keychain, under our own access group (ADR-0001).
struct KeychainSecretStore: SecretStore {
    private func itemQuery(_ service: String, _ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: mytokensAccessGroup,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func mapErr(_ s: OSStatus) -> StoreError {
        s == errSecInteractionNotAllowed ? .locked : .keychain(s)
    }

    func upsert(service: String, account: String, value: String, kind: String, meta: Any?, fields: [String]?, description: String?) throws {
        let comment = try CommentCodec.encode(kind: kind, meta: meta, fields: fields, description: description)
        let changes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrComment as String: comment,
            kSecAttrLabel as String: mytokensLabelPrefix + "\(service)/\(account)",
        ]
        let updated = SecItemUpdate(itemQuery(service, account) as CFDictionary, changes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw mapErr(updated) }

        var add = itemQuery(service, account)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrComment as String] = comment
        add[kSecAttrLabel as String] = "mytokens: \(service)/\(account)"
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw mapErr(added) }
    }

    func get(service: String, account: String) throws -> StoredSecret? {
        var q = itemQuery(service, account)
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true   // also read the comment for the field schema
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecItemNotFound { return nil }
        guard s == errSecSuccess, let attrs = out as? [String: Any],
              let data = attrs[kSecValueData as String] as? Data,
              let str = String(data: data, encoding: .utf8)
        else { throw mapErr(s) }
        let (_, _, fields, _) = CommentCodec.decode(attrs[kSecAttrComment as String] as? String)
        return StoredSecret(value: str, fields: fields)
    }

    func list() throws -> [SecretRecord] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessGroup as String: mytokensAccessGroup,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecUseDataProtectionKeychain as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecItemNotFound { return [] }
        guard s == errSecSuccess, let items = out as? [[String: Any]] else { throw mapErr(s) }
        return items.compactMap { attrs in
            guard let service = attrs[kSecAttrService as String] as? String,
                  let account = attrs[kSecAttrAccount as String] as? String
            else { return nil }
            // Defense-in-depth: only our own items carry this label prefix.
            let label = attrs[kSecAttrLabel as String] as? String
            guard label?.hasPrefix(mytokensLabelPrefix) == true else { return nil }
            let (kind, meta, fields, description) = CommentCodec.decode(attrs[kSecAttrComment as String] as? String)
            return SecretRecord(service: service, account: account, kind: kind, meta: meta,
                                fields: fields, description: description)
        }
    }

    func delete(service: String, account: String) throws -> Bool {
        let s = SecItemDelete(itemQuery(service, account) as CFDictionary)
        if s == errSecItemNotFound { return false }
        guard s == errSecSuccess else { throw mapErr(s) }
        return true
    }
}

// kind + arbitrary user meta + (for a multi-field Secret) the ordered field-label
// schema + an optional agent-authored description are packed into the keychain
// comment attribute as one JSON object:
// {"kind": "...", "meta": <json|null>, "fields": [<label>, …]?, "description": "…"?}.
// "fields"/"description" are omitted when absent, so older items decode unchanged.
enum CommentCodec {
    static func encode(kind: String, meta: Any?, fields: [String]?, description: String?) throws -> String {
        var obj: [String: Any] = ["kind": kind]
        obj["meta"] = (meta == nil || meta is NSNull) ? NSNull() : meta!
        if let fields, !fields.isEmpty { obj["fields"] = fields }
        if let description, !description.isEmpty { obj["description"] = description }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8)
        else { throw StoreError.encoding }
        return s
    }

    static func decode(_ comment: String?) -> (kind: String, meta: String?, fields: [String]?, description: String?) {
        guard let comment, let data = comment.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ("static", nil, nil, nil) }
        let kind = (obj["kind"] as? String) ?? "static"
        let fields = obj["fields"] as? [String]
        let description = obj["description"] as? String
        let meta = (obj["meta"].map { $0 is NSNull ? nil : JSONUtil.compact($0) }) ?? nil
        return (kind, meta, fields, description)
    }
}

enum JSONUtil {
    /// Parse a user-supplied JSON string; nil if invalid.
    static func parse(_ s: String) -> Any? {
        guard let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }

    /// Re-serialize a JSON value to compact, key-sorted text.
    static func compact(_ any: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys, .fragmentsAllowed])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
