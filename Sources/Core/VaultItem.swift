import CryptoKit
import Foundation

// A `server`-level Secret as a 1Password vault item, and back (ADR-0024): the item optokens writes
// for the same Secret (`optokens help secrets`), so `optokens get|env|list` on any machine reads what
// the sync wrote, and the vault holds one format. `decodeVaultItem` is the inverse of `template`.
//
//   title            `<service>`, or `<service>.<account>` for a non-default account
//   category, tags   Secure Note; `optokens`, beside mytokens' own `mytokens` and `mytokens-digest-<hash>`
//   each Field       a field of the section `fields`, in the Secret's order (a lone value: one field `value`),
//                    CONCEALED, or the type the stored item already gives that label
//   the rest         the section `optokens`: service, account, kind, shape (`value` | `fields`),
//                    description and meta (compact JSON) when the Secret has them
//
// The layout holds what optokens holds: a `static` or `profile` Secret of text Fields. A `parent`
// Secret or one with a list Field is not written (`unwritable` says why, and the fix).

/// The section of an item's values, and the section of what is known of the Secret.
let vaultValuesSection = "fields"
let vaultMetadataSection = "optokens"
/// The label of the field a lone (unlabelled) value goes in.
let vaultBareFieldLabel = "value"
/// The tag optokens reads its items by.
let vaultOptokensTag = "optokens"
/// What a vault item the sync owns carries besides: this tag, and a digest tag of what it holds, so
/// one `op item list` shows whether an item is current without reading any value.
let vaultItemTag = "mytokens"
let vaultDigestPrefix = "mytokens-digest-"
/// Changing the layout changes this, so every item written by an older layout reads as changed
/// and the next sync rewrites it once.
private let vaultFormat = "mytokens-vault-4"

private let concealed = "CONCEALED", plain = "STRING"
private let metadataLabels = ["service", "account", "kind", "shape", "description", "meta"]

/// The title of a Secret's vault item: `<service>`, or `<service>.<account>` for a non-default
/// account. No `/`, so `op://<vault>/<title>/fields/<Label>` resolves (a `/` in a title does not).
func vaultItemTitle(service: String, account: String) -> String {
    account == "default" ? service : "\(service).\(account)"
}

/// One `server`-level Secret as a vault item: everything the vault holds about it.
struct VaultItem {
    var service: String
    var account: String
    var kind: String
    var meta: String?             // compact JSON, as the store holds it
    var description: String?
    var secret: SecretValue

    var title: String { vaultItemTitle(service: service, account: account) }

    /// Why the layout cannot hold this Secret, and the command that fixes it; nil when it can.
    var unwritable: (why: String, fix: String)? {
        let name = shellWord(service) + (account == "default" ? "" : " --account \(shellWord(account))")
        if kind != "static" && kind != "profile" {
            return ("it is a \(kind) Secret, which a 1Password item cannot hold",
                    "mytokens put \(name) --kind static")
        }
        if let list = secret.labels.first(where: secret.isList) {
            return ("its Field \"\(list)\" is a list, which a 1Password item cannot hold",
                    "mytokens put \(name) --level personal")
        }
        return nil
    }

    /// The item as the `op item` template wants it. `stored`, the item as `op item get` printed it,
    /// gives each Field it already has its type, and a category's own built-in fields (a Login's
    /// `username` and `password`, which cannot be removed) are kept by id, emptied: their values
    /// are now the section's. Notes are left as they are on an item already in this layout; on any
    /// other they were the Description (the old layout, a hand-made item) and are emptied.
    private func content(forEdit: Bool, stored: [String: Any]?) -> [String: Any] {
        let storedFields = (stored?["fields"] as? [[String: Any]]) ?? []
        let sectionLabels = Dictionary(((stored?["sections"] as? [[String: Any]]) ?? []).compactMap { s -> (String, String)? in
            guard let id = s["id"] as? String else { return nil }
            return (id, (s["label"] as? String) ?? "")
        }, uniquingKeysWith: { a, _ in a })
        func section(_ f: [String: Any]) -> String? {
            guard let s = f["section"] as? [String: Any] else { return nil }
            return (s["label"] as? String) ?? (s["id"] as? String).flatMap { sectionLabels[$0] } ?? ""
        }
        // a Field's type: its field of the section `fields`, else (a hand-made item) a field of its label
        // outside any metadata section (this layout's, or the old layout's `mytokens`)
        var types: [String: String] = [:]
        let byPlace = storedFields.filter { section($0) == vaultValuesSection }
            + storedFields.filter { ![vaultValuesSection, vaultMetadataSection, vaultItemTag].contains(section($0) ?? "") }
        for f in byPlace {
            if let label = f["label"] as? String, let type = f["type"] as? String, type == concealed || type == plain,
               types[label] == nil { types[label] = type }
        }
        func field(_ section: String, _ id: String, _ type: String, _ label: String, _ value: String) -> [String: Any] {
            ["id": "\(section).\(id)", "section": ["id": section], "type": type, "label": label, "value": value]
        }
        let values = secret.isLabelled ? secret.fields : [(label: vaultBareFieldLabel, value: secret.fields[0].value)]
        var fields = values.enumerated().map { i, f in
            field(vaultValuesSection, "\(i)", types[f.label] ?? concealed, f.label, f.value)
        }
        var metadata: [(String, String)] = [("service", service), ("account", account), ("kind", kind),
                                            ("shape", secret.isLabelled ? "fields" : vaultBareFieldLabel)]
        if let description, !description.isEmpty { metadata.append(("description", description)) }
        if let meta { metadata.append(("meta", meta)) }
        fields += metadata.map { field(vaultMetadataSection, $0.0, plain, $0.0, $0.1) }
        if stored != nil {
            let inLayout = storedFields.contains { section($0) == vaultMetadataSection && $0["label"] as? String == "service" }
            for f in storedFields where section(f) == nil {
                guard let purpose = f["purpose"] as? String else { continue }
                if purpose == "NOTES" {
                    if inLayout { fields.append(f) } else {
                        fields.append(["id": f["id"] ?? "notesPlain", "type": plain, "purpose": purpose,
                                       "label": f["label"] ?? "notesPlain", "value": ""])
                    }
                } else {
                    var builtIn = f
                    builtIn["value"] = ""
                    fields.append(builtIn)
                }
            }
        }
        var item: [String: Any] = ["title": title, "fields": fields,
                                   "sections": [["id": vaultValuesSection, "label": vaultValuesSection],
                                                ["id": vaultMetadataSection, "label": vaultMetadataSection]]]
        if !forEdit { item["category"] = "SECURE_NOTE" }
        return item
    }

    private func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// What the item holds, hashed: equal digests, equal Secrets (a Field's type is not counted).
    /// Not a way to read a value back (the vault holds the values anyway).
    var digest: String {
        var data = Data(vaultFormat.utf8)
        data.append(encode(content(forEdit: false, stored: nil)))
        return SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The `op item` template, on stdin. `stored`: the item it is written over (see `content`).
    /// `forEdit`: no category, so an item taken over keeps the one it has.
    func template(forEdit: Bool = false, over stored: Data? = nil) -> Data {
        let storedItem = stored.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        var item = content(forEdit: forEdit, stored: storedItem)
        item["tags"] = [vaultOptokensTag, vaultItemTag, vaultDigestPrefix + digest]
        return encode(item)
    }
}

/// The `op item edit` template (on stdin) that makes `stored` (as `op item get` printed it) the sync's own
/// and changes nothing else: its tags gain `mytokens` and the digest tag of `digest` (an older
/// digest tag replaced); every other tag, its title, its sections and every field (notes, types, ids) are
/// sent back as they are, so optokens reads the item unchanged. nil when `stored` is not an item.
func vaultRetagTemplate(_ stored: Data, digest: String) -> Data? {
    guard let root = try? jsonObject(stored) else { return nil }
    var tags = ((root["tags"] as? [String]) ?? []).filter { $0 != vaultItemTag && !$0.hasPrefix(vaultDigestPrefix) }
    tags += [vaultItemTag, vaultDigestPrefix + digest]
    var item: [String: Any] = ["tags": tags]
    for key in ["title", "sections", "fields"] { item[key] = root[key] }
    return try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys, .withoutEscapingSlashes])
}

/// Why an item is not a Secret.
struct VaultDecodeError: Error, CustomStringConvertible {
    var description: String
}

private func jsonObject(_ json: Data) throws -> [String: Any] {
    guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
        throw VaultDecodeError(description: "not a JSON object")
    }
    return root
}

/// Each field of an item with the label of its section (nil: none, the category's own), as `op`
/// names a field's section by its id, its label or both.
private func sectionedFields(_ root: [String: Any]) -> [(field: [String: Any], section: String?)] {
    var labels: [String: String] = [:]
    for s in (root["sections"] as? [[String: Any]]) ?? [] {
        if let id = s["id"] as? String { labels[id] = (s["label"] as? String) ?? "" }
    }
    return ((root["fields"] as? [[String: Any]]) ?? []).map { f in
        guard let s = f["section"] as? [String: Any] else { return (f, nil) }
        return (f, (s["label"] as? String) ?? (s["id"] as? String).flatMap { labels[$0] } ?? "")
    }
}

/// Whether an item is in optokens' layout: tagged `optokens`, with a section `optokens`.
func isOptokensItem(_ json: Data) -> Bool {
    guard let root = try? jsonObject(json), ((root["tags"] as? [String]) ?? []).contains(vaultOptokensTag) else { return false }
    return sectionedFields(root).contains { $0.section == vaultMetadataSection }
}

/// `op item get --format json` (or a template) of an item in optokens' layout → the Secret it holds:
/// the inverse of `VaultItem.template`. What optokens refuses, this throws on; the name is read from
/// the section `optokens`, never from the title. Notes and other sections are not the Secret's.
func decodeVaultItem(_ json: Data) throws -> VaultItem {
    func bad(_ why: String) -> VaultDecodeError { VaultDecodeError(description: why) }
    let root = try jsonObject(json)
    guard ((root["tags"] as? [String]) ?? []).contains(vaultOptokensTag) else { throw bad("it has no tag \"\(vaultOptokensTag)\"") }
    var values: [(label: String, value: String)] = []
    var metadata: [String: String] = [:]
    for (f, section) in sectionedFields(root) {
        let label = (f["label"] as? String) ?? ""
        let value = (f["value"] as? String) ?? ""          // op leaves `value` out of an empty field
        if section == vaultValuesSection {
            guard let type = f["type"] as? String, type == concealed || type == plain else {
                throw bad("its field \"\(label)\" in the section \"\(vaultValuesSection)\" is neither \(concealed) nor \(plain)")
            }
            values.append((label, value))
        } else if section == vaultMetadataSection {
            guard metadataLabels.contains(label) else { throw bad("its section \"\(vaultMetadataSection)\" has a field \"\(label)\"") }
            guard metadata[label] == nil else { throw bad("its section \"\(vaultMetadataSection)\" has \"\(label)\" twice") }
            metadata[label] = value
        }
    }
    func need(_ name: String) throws -> String {
        guard let v = metadata[name] else { throw bad("no \"\(name)\" in the section \"\(vaultMetadataSection)\"") }
        return v
    }
    let kind = try need("kind")
    guard kind == "static" || kind == "profile" else { throw bad("its kind is \"\(kind)\", neither static nor profile") }
    if let meta = metadata["meta"], !(JSONUtil.parse(meta) is [String: Any]) { throw bad("its meta is not a JSON object") }
    let secret: SecretValue
    switch try need("shape") {
    case vaultBareFieldLabel:
        guard values.count == 1, values[0].label == vaultBareFieldLabel else {
            throw bad("it is a single value, but its section \"\(vaultValuesSection)\" is not one field \"\(vaultBareFieldLabel)\"")
        }
        secret = SecretValue(single: values[0].value)
    case "fields":
        guard !values.isEmpty else { throw bad("its section \"\(vaultValuesSection)\" has no field") }
        for (i, f) in values.enumerated() where f.label.isEmpty || values[..<i].contains(where: { $0.label == f.label }) {
            throw bad("its section \"\(vaultValuesSection)\" has the label \"\(f.label)\" empty or twice")
        }
        secret = SecretValue(fields: values)
    case let shape:
        throw bad("its shape is \"\(shape)\", neither \"\(vaultBareFieldLabel)\" nor \"fields\"")
    }
    return VaultItem(service: try need("service"), account: try need("account"), kind: kind, meta: metadata["meta"],
                     description: metadata["description"], secret: secret)
}

/// An item someone made in 1Password (any category) → the Secret it would be: title → service
/// (`<service>.<account>` when the title has exactly one dot, else the whole title with account
/// `default`), notes → Description, each non-empty field → a Field labelled as in 1Password. Empty
/// and null values are skipped (a Login's and an API Credential's built-ins), and so are fields of a
/// section with no label (1Password's own). Throws why it cannot be mapped without loss.
func decodeHandMadeItem(_ json: Data, title: String) throws -> VaultItem {
    func bad(_ why: String) -> VaultDecodeError { VaultDecodeError(description: why) }
    let root = try jsonObject(json)
    if root["category"] as? String == "DOCUMENT" || !((root["files"] as? [Any]) ?? []).isEmpty { throw bad("it holds a file") }
    if title.isEmpty { throw bad("it has no title") }
    var notes: String?
    var fields: [(label: String, value: String)] = []
    for (f, section) in sectionedFields(root) {
        let value = (f["value"] as? String) ?? ""
        let label = (f["label"] as? String) ?? ""
        if f["purpose"] as? String == "NOTES" { notes = value.isEmpty ? nil : value; continue }
        if section == "" || value.isEmpty { continue }
        if label.isEmpty { throw bad("a field of the section \"\(section ?? "")\" has no label") }
        if fields.contains(where: { $0.label == label }) { throw bad("two fields labelled \"\(label)\"") }
        fields.append((label, value))
    }
    guard !fields.isEmpty else { throw bad("it holds no values") }
    let parts = title.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    let (service, account) = parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty ? (parts[0], parts[1]) : (title, "default")
    return VaultItem(service: service, account: account, kind: "static", meta: nil, description: notes,
                     secret: SecretValue(fields: fields))
}

/// An item the sync did not make → the Secret to Adopt: one optokens wrote is read in its layout
/// (its name from its section), any other as hand-made.
func decodeForeignItem(_ json: Data, title: String) throws -> VaultItem {
    isOptokensItem(json) ? try decodeVaultItem(json) : try decodeHandMadeItem(json, title: title)
}
