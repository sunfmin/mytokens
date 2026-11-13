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
    var pushed: Bool          // a Server's copy written or adopted by `sync`, which may also remove it (ADR-0012)
    var adopted = false       // a Server's: entered here, then adopted by a personal Mac — so it may change here (ADR-0018)
    var origin: String? = nil // a personal Mac's: the Server it was adopted from (ADR-0018)
    var changed = false       // changed at its origin or here since the last sync with that Server (ADR-0018)

    /// What `sync` has marked on it, as `upsert` takes it back.
    var marks: SyncMarks { SyncMarks(pushed: pushed, adopted: adopted, origin: origin, changed: changed) }
}

/// What `sync` records on a stored Secret (ADR-0012, ADR-0018), apart from its values:
/// - `pushed` (a Server's): a personal Mac's copy, which the next sync may update or remove.
/// - `adopted` (a Server's, with `pushed`): entered here and adopted by a personal Mac. The
///   Server is its origin, so it may still change it in place.
/// - `origin` (a personal Mac's): the Server an adopted Secret was entered on.
/// - `changed`: changed since the last sync between the personal Mac and that Server — on
///   the Server, by its own `put`; on a personal Mac, by `put` into a Secret with an origin.
struct SyncMarks: Equatable {
    var pushed = false
    var adopted = false
    var origin: String? = nil
    var changed = false
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
            return "keychain is locked (interaction not allowed) — the Mac has not been unlocked since it booted: log in once (at the Mac or over Screen Sharing), then retry"
        case .encoding:
            return "failed to encode/decode item metadata"
        }
    }
}

/// The lowest-level seam for stored Secrets. The real impl talks to the data-protection
/// keychain location the Mac's role picks; tests use an in-memory fake. Secrets cross
/// this seam as structured `SecretValue` Fields — the single-vs-JSON on-disk
/// encoding (ADR-0005) lives inside the implementation, not in the caller.
protocol SecretStore {
    func upsert(service: String, account: String, secret: SecretValue, kind: String, meta: Any?, description: String?, level: Level, marks: SyncMarks) throws
    func get(service: String, account: String) throws -> SecretValue?   // nil if absent
    func list() throws -> [SecretRecord]
    func delete(service: String, account: String) throws -> Bool   // false if absent
}

extension SecretStore {
    /// `upsert` with only the pushed mark set (or none).
    func upsert(service: String, account: String, secret: SecretValue, kind: String, meta: Any?, description: String?, level: Level, pushed: Bool) throws {
        try upsert(service: service, account: account, secret: secret, kind: kind, meta: meta,
                   description: description, level: level, marks: SyncMarks(pushed: pushed))
    }
}

// Must match the `keychain-access-groups` entitlement (= application-identifier).
// macOS does NOT isolate data-protection queries by group for non-sandboxed apps,
// so every query is scoped to this group explicitly to avoid touching other apps' items.
let mytokensAccessGroup = "HL27PWAKDF.com.sunfmin.mytokens"
private let mytokensLabelPrefix = "mytokens: "

/// Which keychain a `KeychainSecretStore` acts on — chosen by the Mac's role (ADR-0010).
enum KeychainLocation {
    /// Synchronizable items in the data-protection keychain under our own access group:
    /// a personal Mac's store (ADR-0001).
    case iCloud
    /// Non-synchronizable items in the same data-protection keychain: a Server's store,
    /// readable over SSH after its first unlock since boot (ADR-0013 amends ADR-0010).
    case local
}

/// The four SecItem calls the store makes, behind a seam so tests can drive the real
/// `KeychainSecretStore` query logic against an in-memory keychain. Signatures mirror
/// the Security framework's; `SystemKeychain` forwards to it unchanged.
protocol Keychain {
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any], _ result: inout CFTypeRef?) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychain: Keychain {
    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, changes as CFDictionary)
    }
    func copyMatching(_ query: [String: Any], _ result: inout CFTypeRef?) -> OSStatus {
        SecItemCopyMatching(query as CFDictionary, &result)
    }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

/// Real store: generic-password items in the data-protection keychain, synchronizable on
/// a personal Mac (ADR-0001) and local-only on a Server (ADR-0013).
struct KeychainSecretStore: SecretStore {
    var location: KeychainLocation = .iCloud
    var keychain: Keychain = SystemKeychain()

    /// The store for `location`, with every item already at the accessibility it is
    /// written with — so a Secret stored by an older build becomes readable while the
    /// screen is locked the first time any command runs on an unlocked Mac (ADR-0011).
    static func opened(_ location: KeychainLocation, keychain: Keychain = SystemKeychain()) -> KeychainSecretStore {
        let store = KeychainSecretStore(location: location, keychain: keychain)
        _ = store.migrateAccessibility()
        return store
    }

    /// The scoping every query shares. This is the one invariant that must never vary
    /// across operations — if `list` and `upsert` disagreed on it, `list` would stop
    /// seeing stored items — so it lives in exactly one place, per location.
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessGroup as String: mytokensAccessGroup,
            kSecAttrSynchronizable as String: location == .iCloud ? kCFBooleanTrue! : kCFBooleanFalse!,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// When an item's value may be read, set on every write. A Secret is readable once
    /// the Mac has been unlocked since boot, screen locked or not (ADR-0011, ADR-0013).
    /// Not a query key: an item still at the old default must stay findable.
    private var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlock }

    /// The accessibility an older build left items at: the system default, never set explicitly.
    private var formerAccessibility: CFString { kSecAttrAccessibleWhenUnlocked }

    /// Move every item still at `formerAccessibility` to `accessibility`, values and
    /// attributes untouched, no popup. Idempotent: once moved, nothing matches. Best
    /// effort — while the screen is locked the old items can't be touched
    /// (`errSecInteractionNotAllowed`), and the next run on an unlocked Mac moves them.
    /// Returns the keychain status, for tests; `errSecItemNotFound` means nothing to move.
    @discardableResult
    func migrateAccessibility() -> OSStatus {
        var q = baseQuery
        q[kSecAttrAccessible as String] = formerAccessibility
        return keychain.update(q, [kSecAttrAccessible as String: accessibility])
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

    func upsert(service: String, account: String, secret: SecretValue, kind: String, meta: Any?, description: String?, level: Level, marks: SyncMarks) throws {
        // The label schema is recorded for a labelled Secret only; the value's
        // encoding follows from it — raw bytes for the lone unlabelled value, a
        // {label: value} JSON object for labelled Fields (ADR-0005).
        let comment = try CommentCodec.encode(kind: kind, meta: meta, fields: secret.schema, description: description, level: level, marks: marks)
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
            kSecAttrAccessible as String: accessibility,
        ]
        let updated = keychain.update(itemQuery(service, account), changes)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw mapErr(updated) }

        let add = itemQuery(service, account).merging(changes) { _, new in new }
        let added = keychain.add(add)
        guard added == errSecSuccess else { throw mapErr(added) }
    }

    func get(service: String, account: String) throws -> SecretValue? {
        var q = itemQuery(service, account)
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true   // also read the comment for the field schema
        var out: CFTypeRef?
        let s = keychain.copyMatching(q, &out)
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
        let s = keychain.copyMatching(q, &out)
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
                                fields: c.fields, description: c.description, level: c.level, pushed: c.marks.pushed,
                                adopted: c.marks.adopted, origin: c.marks.origin, changed: c.marks.changed)
        }
    }

    func delete(service: String, account: String) throws -> Bool {
        let s = keychain.delete(itemQuery(service, account))
        if s == errSecItemNotFound { return false }
        guard s == errSecSuccess else { throw mapErr(s) }
        return true
    }
}

// kind + arbitrary user meta + (for a multi-field Secret) the ordered field-label
// schema + an optional agent-authored description + the level are packed into the
// keychain comment attribute as one JSON object:
// {"kind": "...", "level": "...", "meta": <json|null>, "fields": [<label>, …]?, "description": "…"?, "pushed": true?,
//  "adopted": true?, "origin": "<host>"?, "changed": true?}.
// "fields"/"description" and the sync marks are omitted when absent; an item stored before levels has no
// "level" and decodes as `personal` (ADR-0010), so older items decode unchanged.
enum CommentCodec {
    static func encode(kind: String, meta: Any?, fields: [String]?, description: String?, level: Level, marks: SyncMarks) throws -> String {
        var obj: [String: Any] = ["kind": kind, "level": level.rawValue]
        obj["meta"] = (meta == nil || meta is NSNull) ? NSNull() : meta!
        if let fields, !fields.isEmpty { obj["fields"] = fields }
        if let description, !description.isEmpty { obj["description"] = description }
        if marks.pushed { obj["pushed"] = true }
        if marks.adopted { obj["adopted"] = true }
        if let origin = marks.origin { obj["origin"] = origin }
        if marks.changed { obj["changed"] = true }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8)
        else { throw StoreError.encoding }
        return s
    }

    static func decode(_ comment: String?) -> (kind: String, meta: String?, fields: [String]?, description: String?, level: Level, marks: SyncMarks) {
        guard let comment, let data = comment.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ("static", nil, nil, nil, .default, SyncMarks()) }
        let kind = (obj["kind"] as? String) ?? "static"
        let fields = obj["fields"] as? [String]
        let description = obj["description"] as? String
        let meta = (obj["meta"].map { $0 is NSNull ? nil : JSONUtil.compact($0) }) ?? nil
        // No level, or one this build doesn't know, travels nowhere: personal.
        let level = (obj["level"] as? String).flatMap(Level.init(rawValue:)) ?? .default
        let marks = SyncMarks(pushed: (obj["pushed"] as? Bool) ?? false, adopted: (obj["adopted"] as? Bool) ?? false,
                              origin: obj["origin"] as? String, changed: (obj["changed"] as? Bool) ?? false)
        return (kind, meta, fields, description, level, marks)
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
