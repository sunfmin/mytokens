import Foundation
import Security

// The non-secret view of a stored item (no value) — used by `list`.
struct SecretRecord {
    var service: String
    var account: String
    var kind: String          // "static" | "parent" | "profile"
    var meta: String?         // compact JSON, or nil
    var fields: [String]?     // ordered field labels for a multi-field Secret, else nil
    var description: String?  // agent-authored purpose note (ADR-0006), or nil
    var level: Level          // how far the Secret may travel (ADR-0010)
}

/// How far a Secret may travel (ADR-0010). `personal` stays in the iCloud Keychain on
/// the user's own Macs; `server` may also be pushed to the user's servers. A Secret
/// stored before levels existed has none recorded and reads as `personal`, the default.
enum Level: String, CaseIterable {
    case personal, server

    static let `default`: Level = .personal

    /// The allowed values as the CLI spells them, for error messages.
    static var allowed: String { allCases.map { "'\($0.rawValue)'" }.joined(separator: " or ") }
}

// The value payload of a Secret: one or more ordered Fields (ADR-0005), each a
// `(label, value)` pair. A lone Field with an empty label is the unlabelled
// bare-value Secret (ADR-0002); any labelled Fields serialize as a JSON object.
// This is the currency of the store seam — callers add and read Secrets as
// structured Fields and never touch the on-disk encoding.
struct SecretValue {
    let fields: [(label: String, value: String)]

    /// The unlabelled single-value Secret (today's common path).
    init(single value: String) { self.fields = [(label: "", value: value)] }
    init(fields: [(label: String, value: String)]) { self.fields = fields }

    /// True when the Secret carries labelled Fields (⇒ JSON storage); false for the
    /// lone unlabelled value (⇒ raw storage). Derived — the shape is never recorded twice.
    var isLabelled: Bool { !(fields.count == 1 && fields[0].label.isEmpty) }

    /// The ordered label schema for a labelled Secret; nil for the bare value.
    var schema: [String]? { isLabelled ? fields.map(\.label) : nil }

    /// Every Field's label, in order.
    var labels: [String] { fields.map(\.label) }

    /// The lone value when the Secret has exactly one Field — what bare `get`
    /// returns (ADR-0005's "1 field ⇒ bare get works" rule).
    var loneValue: String? { fields.count == 1 ? fields[0].value : nil }

    /// A Field's value by label, or nil if there is no such Field.
    func value(forField label: String) -> String? { fields.first { $0.label == label }?.value }

    /// The `{label: value}` object as compact, key-sorted JSON: the on-disk form of
    /// a labelled Secret (ADR-0005).
    func compactJSON() -> String? {
        var obj: [String: String] = [:]
        for f in fields { obj[f.label] = f.value }
        return JSONUtil.compact(obj)
    }
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

/// The lowest-level seam for stored Secrets. The real impl talks to the keychain the
/// Mac's role picks (iCloud or login); tests use an in-memory fake. Secrets cross
/// this seam as structured `SecretValue` Fields — the single-vs-JSON on-disk
/// encoding (ADR-0005) lives inside the implementation, not in the caller.
protocol SecretStore {
    func upsert(service: String, account: String, secret: SecretValue, kind: String, meta: Any?, description: String?, level: Level) throws
    func get(service: String, account: String) throws -> SecretValue?   // nil if absent
    func list() throws -> [SecretRecord]
    func delete(service: String, account: String) throws -> Bool   // false if absent
}

// Must match the `keychain-access-groups` entitlement (= application-identifier).
// macOS does NOT isolate data-protection queries by group for non-sandboxed apps,
// so every query is scoped to this group explicitly to avoid touching other apps' items.
private let mytokensAccessGroup = "HL27PWAKDF.com.sunfmin.mytokens"
private let mytokensLabelPrefix = "mytokens: "

/// Which keychain a `KeychainSecretStore` acts on — chosen by the Mac's role (ADR-0010).
enum KeychainLocation {
    /// Synchronizable items in the data-protection keychain under our own access group:
    /// a personal Mac's store (ADR-0001).
    case iCloud
    /// Local items in the login keychain, readable while the screen is locked: a
    /// Server's store, which does not sign into iCloud (ADR-0010 narrows ADR-0001).
    case login
}

// The login keychain has no access groups, so our items there carry this creator code
// ('mytk') and every query is scoped to it — never touching another app's items.
private let mytokensCreator: UInt32 = 0x6D79_746B

/// Real store: generic-password items in the keychain `location` names — the iCloud
/// Keychain on a personal Mac (ADR-0001), the login keychain on a Server (ADR-0010).
struct KeychainSecretStore: SecretStore {
    var location: KeychainLocation = .iCloud

    /// The scoping every query shares. This is the one invariant that must never vary
    /// across operations — if `list` and `upsert` disagreed on it, `list` would stop
    /// seeing stored items — so it lives in exactly one place, per location.
    private var baseQuery: [String: Any] {
        switch location {
        case .iCloud:
            return [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccessGroup as String: mytokensAccessGroup,
                kSecAttrSynchronizable as String: kCFBooleanTrue!,
                kSecUseDataProtectionKeychain as String: true,
            ]
        case .login:
            return [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrCreator as String: mytokensCreator,
                kSecUseDataProtectionKeychain as String: false,
            ]
        }
    }

    /// `baseQuery` narrowed to a single item by service + account.
    private func itemQuery(_ service: String, _ account: String) -> [String: Any] {
        var q = baseQuery
        q[kSecAttrService as String] = service
        q[kSecAttrAccount as String] = account
        return q
    }

    private func mapErr(_ s: OSStatus) -> StoreError {
        s == errSecInteractionNotAllowed ? .locked : .keychain(s)
    }

    func upsert(service: String, account: String, secret: SecretValue, kind: String, meta: Any?, description: String?, level: Level) throws {
        // The label schema is recorded for a labelled Secret only; the value's
        // encoding follows from it — raw bytes for the lone unlabelled value, a
        // {label: value} JSON object for labelled Fields (ADR-0005).
        let comment = try CommentCodec.encode(kind: kind, meta: meta, fields: secret.schema, description: description, level: level)
        let storedValue: String
        if secret.isLabelled {
            guard let json = secret.compactJSON() else { throw StoreError.encoding }
            storedValue = json
        } else {
            storedValue = secret.fields[0].value
        }
        let changes: [String: Any] = [
            kSecValueData as String: Data(storedValue.utf8),
            kSecAttrComment as String: comment,
            kSecAttrLabel as String: mytokensLabelPrefix + "\(service)/\(account)",
        ]
        let updated = SecItemUpdate(itemQuery(service, account) as CFDictionary, changes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw mapErr(updated) }

        var add = itemQuery(service, account)
        add[kSecValueData as String] = Data(storedValue.utf8)
        add[kSecAttrComment as String] = comment
        add[kSecAttrLabel as String] = mytokensLabelPrefix + "\(service)/\(account)"
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw mapErr(added) }
    }

    func get(service: String, account: String) throws -> SecretValue? {
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
        let schema = CommentCodec.decode(attrs[kSecAttrComment as String] as? String).fields

        // No schema ⇒ the raw bytes are the lone unlabelled value (ADR-0002).
        guard let schema else { return SecretValue(single: str) }

        // Labelled ⇒ the bytes are a {label: value} object; rebuild Fields in schema
        // order. A value that fails to decode is a corrupt item, surfaced as an error.
        guard let obj = JSONUtil.parse(str) as? [String: Any] else { throw StoreError.encoding }
        var fields: [(label: String, value: String)] = []
        for label in schema {
            guard let v = obj[label] as? String else { throw StoreError.encoding }
            fields.append((label: label, value: v))
        }
        return SecretValue(fields: fields)
    }

    func list() throws -> [SecretRecord] {
        // Same scoping as every other op, widened to all items with their attributes.
        var q = baseQuery
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        q[kSecReturnAttributes as String] = true
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
            let c = CommentCodec.decode(attrs[kSecAttrComment as String] as? String)
            return SecretRecord(service: service, account: account, kind: c.kind, meta: c.meta,
                                fields: c.fields, description: c.description, level: c.level)
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
// schema + an optional agent-authored description + the level are packed into the
// keychain comment attribute as one JSON object:
// {"kind": "...", "level": "...", "meta": <json|null>, "fields": [<label>, …]?, "description": "…"?}.
// "fields"/"description" are omitted when absent; an item stored before levels has no
// "level" and decodes as `personal` (ADR-0010), so older items decode unchanged.
enum CommentCodec {
    static func encode(kind: String, meta: Any?, fields: [String]?, description: String?, level: Level) throws -> String {
        var obj: [String: Any] = ["kind": kind, "level": level.rawValue]
        obj["meta"] = (meta == nil || meta is NSNull) ? NSNull() : meta!
        if let fields, !fields.isEmpty { obj["fields"] = fields }
        if let description, !description.isEmpty { obj["description"] = description }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8)
        else { throw StoreError.encoding }
        return s
    }

    static func decode(_ comment: String?) -> (kind: String, meta: String?, fields: [String]?, description: String?, level: Level) {
        guard let comment, let data = comment.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ("static", nil, nil, nil, .default) }
        let kind = (obj["kind"] as? String) ?? "static"
        let fields = obj["fields"] as? [String]
        let description = obj["description"] as? String
        let meta = (obj["meta"].map { $0 is NSNull ? nil : JSONUtil.compact($0) }) ?? nil
        // No level, or one this build doesn't know, travels nowhere: personal.
        let level = (obj["level"] as? String).flatMap(Level.init(rawValue:)) ?? .default
        return (kind, meta, fields, description, level)
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
