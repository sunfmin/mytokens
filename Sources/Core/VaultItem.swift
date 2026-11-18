import CryptoKit
import Foundation

// A Secret as a 1Password vault item, and back (ADR-0022, amended by mytokens#10). The mapping is
// lossless: an item holds everything a Secret is, so a server with `op` and `jq` and no mytokens
// reads all of it (skills/mytokens/op/*.jq), and `decodeVaultItem` is the inverse of `template`.
//
//   Description      → the notes (`notesPlain`); none ⇄ no notes
//   text Field       → a top-level CONCEALED field labelled by the Field (a lone unlabelled value:
//                      `value`), so `op read "op://<vault>/<title>/<Label>"` keeps working
//   list Field       → one section per record `<Label> [<i>]` (1-based), one CONCEALED field per key
//   the rest         → the section `mytokens`, plain STRING fields (below)
//
// The metadata section is a section, not top-level fields, so a Field named `kind` still reads
// by `op read` as the Field. Its fields: service, account, kind, level, shape (`bare` for the lone
// unlabelled value, `fields` for labelled ones), order (the Fields' labels in order, a JSON
// array), and meta (compact JSON; absent when the Secret has none).

/// The label of the metadata section.
let vaultMetadataSection = "mytokens"
/// The label of the Field a bare (unlabelled) Secret's value goes in.
let vaultBareFieldLabel = "value"
/// What a vault item made by mytokens carries: this tag, and a digest tag of what it holds, so
/// one `op item list` shows whether an item is current without reading any value.
let vaultItemTag = "mytokens"
let vaultDigestPrefix = "mytokens-digest-"
/// Changing the mapping changes this, so every item written by an older mapping reads as changed.
private let vaultFormat = "mytokens-vault-2"

/// The title of a Secret's vault item: `<service>`, or `<service>.<account>` for a non-default
/// account. No `/`, so `op://<vault>/<title>/<Label>` resolves (a `/` in a title does not).
func vaultItemTitle(service: String, account: String) -> String {
    account == "default" ? service : "\(service).\(account)"
}

/// One Secret as a vault item: everything the store holds about it.
struct VaultItem {
    var service: String
    var account: String
    var kind: String
    var meta: String?             // compact JSON, as the store holds it
    var description: String?
    var level: Level
    var secret: SecretValue

    var title: String { vaultItemTitle(service: service, account: account) }

    /// The item's content as the template wants it, without tags: what the digest is taken over.
    private func content(forEdit: Bool, loginIds: Bool = false) -> [String: Any] {
        var fields: [[String: Any]] = []
        var sections: [[String: Any]] = []
        for f in secret.fields {
            let label = f.label.isEmpty ? vaultBareFieldLabel : f.label
            if secret.isList(f.label), let records = ListValue.records(f.value) {
                // 1Password has no list type: one section per record, `<Label> [<i>]` (1-based),
                // one concealed field per key, in key order (ADR-0020).
                for (i, record) in records.enumerated() {
                    let section: [String: Any] = ["id": "section\(sections.count)", "label": "\(label) [\(i + 1)]"]
                    sections.append(section)
                    for key in record.keys.sorted() {
                        fields.append(["id": "field\(fields.count)", "label": key, "type": "CONCEALED",
                                       "value": record[key]!, "section": section])
                    }
                }
            } else if loginIds && label == "username" {      // a Login's built-ins cannot be removed: reuse their ids
                fields.append(["id": "username", "label": label, "type": "STRING", "purpose": "USERNAME", "value": f.value])
            } else if loginIds && label == "password" {
                fields.append(["id": "password", "label": label, "type": "CONCEALED", "purpose": "PASSWORD", "value": f.value])
            } else {
                fields.append(["id": "field\(fields.count)", "label": label, "type": "CONCEALED", "value": f.value])
            }
        }
        let section: [String: Any] = ["id": vaultMetadataSection, "label": vaultMetadataSection]
        sections.append(section)
        var metadata: [(String, String)] = [("service", service), ("account", account), ("kind", kind), ("level", level.rawValue),
                                            ("shape", secret.isLabelled ? "fields" : "bare"),
                                            ("order", JSONUtil.compact(secret.fields.map { $0.label.isEmpty ? vaultBareFieldLabel : $0.label }) ?? "[]")]
        if let meta { metadata.append(("meta", meta)) }
        for (label, value) in metadata {
            fields.append(["id": "field\(fields.count)", "label": label, "type": "STRING", "value": value, "section": section])
        }
        if let description, !description.isEmpty {
            fields.append(["id": "notesPlain", "label": "notesPlain", "type": "STRING", "purpose": "NOTES", "value": description])
        }
        var item: [String: Any] = ["title": title, "fields": fields, "sections": sections]
        if !forEdit { item["category"] = "SECURE_NOTE" }
        return item
    }

    private func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// What the item holds, hashed: equal digests, equal items. Not a way to read a value back
    /// (the vault holds the values anyway).
    var digest: String {
        var data = Data(vaultFormat.utf8)
        data.append(encode(content(forEdit: false)))
        return SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The `op item` template, on stdin. Category Secure Note: `op item list --format json` shows
    /// the start of its notes as `additional_information` (an API Credential shows null), so the
    /// Description shows in a list. `forEdit`: no category, so an item taken over keeps the one it has.
    /// `loginIds`: the item is a Login, whose `username` and `password` fields keep their ids.
    func template(forEdit: Bool = false, loginIds: Bool = false) -> Data {
        var item = content(forEdit: forEdit, loginIds: loginIds)
        item["tags"] = [vaultItemTag, vaultDigestPrefix + digest]
        return encode(item)
    }
}

/// Why an item is not a Secret.
struct VaultDecodeError: Error, CustomStringConvertible {
    var description: String
}

/// An item's JSON read without meaning: its notes, its mytokens metadata, and every non-empty
/// field in item order. Empty and null values are skipped (a Login's and an API Credential's
/// built-ins), and so are fields of a section with no label (1Password's own).
private struct RawItem {
    var notes: String?
    var metadata: [String: String] = [:]
    var cells: [(label: String, value: String, section: String?)] = []
    var category: String?
    var hasFiles = false

    init(_ json: Data) throws {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            throw VaultDecodeError(description: "not a JSON object")
        }
        category = root["category"] as? String
        hasFiles = !((root["files"] as? [Any]) ?? []).isEmpty
        for f in (root["fields"] as? [[String: Any]]) ?? [] {
            let value = (f["value"] as? String) ?? ""
            let label = (f["label"] as? String) ?? ""
            if f["purpose"] as? String == "NOTES" { notes = value.isEmpty ? nil : value; continue }
            let section = ((f["section"] as? [String: Any])?["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if section == vaultMetadataSection { metadata[label] = value; continue }
            if value.isEmpty { continue }
            cells.append((label, value, section))
        }
    }
}

private struct Interpreted {
    var fields: [(label: String, value: String)] = []
    var lists: Set<String> = []
    var labels: [String] { fields.map(\.label) }
}

/// The Fields a set of cells make: a field of a section named `<Label> [<i>]` is a record of the
/// list `<Label>`; every other field is a text Field labelled as in 1Password. Two Fields of one
/// label cannot be kept apart, so they throw.
private func interpret(_ cells: [(label: String, value: String, section: String?)]) throws -> Interpreted {
    func bad(_ why: String) -> VaultDecodeError { VaultDecodeError(description: why) }
    var order: [String] = []
    var text: [String: String] = [:]
    var records: [String: [String: [String: String]]] = [:]     // list label → section label → record
    var indexes: [String: [String: Int]] = [:]
    for c in cells {
        if let s = c.section, s.hasSuffix("]"), let open = s.range(of: " [", options: .backwards),
           let i = Int(s[open.upperBound..<s.index(before: s.endIndex)]) {
            let list = String(s[..<open.lowerBound])
            if records[list] == nil { order.append(list) }
            if records[list]?[s]?[c.label] != nil { throw bad("two fields labelled \"\(c.label)\" in \"\(s)\"") }
            records[list, default: [:]][s, default: [:]][c.label] = c.value
            indexes[list, default: [:]][s] = i
        } else {
            if text[c.label] != nil { throw bad("two fields labelled \"\(c.label)\"") }
            text[c.label] = c.value
            order.append(c.label)
        }
    }
    var out = Interpreted()
    for label in order {
        if let sections = records[label] {
            if text[label] != nil { throw bad("\"\(label)\" is both a field and a list") }
            let sorted = sections.keys.sorted { (indexes[label]![$0]!, $0) < (indexes[label]![$1]!, $1) }.map { sections[$0]! }
            guard let compact = JSONUtil.compact(sorted), let canonical = ListValue.canonical(compact) else {
                throw bad("list \"\(label)\" is not a list of records")
            }
            out.fields.append((label, canonical)); out.lists.insert(label)
        } else {
            out.fields.append((label, text[label]!))
        }
    }
    return out
}

/// `op item get --format json` (or a template) of an item mytokens made → the Secret it holds: the
/// inverse of `VaultItem.template`. A field or section added in 1Password after the metadata's
/// `order` is kept too, after the others.
func decodeVaultItem(_ json: Data) throws -> VaultItem {
    func bad(_ why: String) -> VaultDecodeError { VaultDecodeError(description: why) }
    let raw = try RawItem(json)
    let all = try interpret(raw.cells)
    func need(_ name: String) throws -> String {
        guard let v = raw.metadata[name] else { throw bad("no \"\(name)\" in the \(vaultMetadataSection) section") }
        return v
    }
    guard let level = Level(rawValue: try need("level")) else { throw bad("unknown level \"\(raw.metadata["level"] ?? "")\"") }
    guard let order = JSONUtil.parse(try need("order")) as? [String] else { throw bad("\"order\" is not a JSON array of labels") }
    let bare = try need("shape") == "bare"
    var fields: [(label: String, value: String)] = []
    for label in order {
        // an empty value is not read back as a cell: a Field in `order` without one is empty
        fields.append(all.fields.first(where: { $0.label == label }) ?? (label, ""))
    }
    let extras = all.fields.filter { f in !order.contains(f.label) }
    let secret: SecretValue
    if bare && extras.isEmpty {
        guard fields.count == 1 else { throw bad("no \"\(vaultBareFieldLabel)\" field") }
        secret = SecretValue(single: fields[0].value)
    } else {
        secret = SecretValue(fields: fields + extras, lists: all.lists)
    }
    return VaultItem(service: try need("service"), account: try need("account"), kind: try need("kind"),
                     meta: raw.metadata["meta"], description: raw.notes, level: level, secret: secret)
}

/// An item someone made in 1Password (any category) → the Secret it would be: title → service
/// (`<service>.<account>` when the title has exactly one dot, else the whole title with account
/// `default`), notes → Description, each non-empty field → a Field labelled as in 1Password, a section
/// `<Label> [<i>]` → a list Field. Throws why it cannot be mapped without loss.
func decodeHandMadeItem(_ json: Data, title: String) throws -> VaultItem {
    func bad(_ why: String) -> VaultDecodeError { VaultDecodeError(description: why) }
    let raw = try RawItem(json)
    if raw.category == "DOCUMENT" || raw.hasFiles { throw bad("it holds a file") }
    if title.isEmpty { throw bad("it has no title") }
    if let c = raw.cells.first(where: { $0.label.isEmpty }) { throw bad("a field of the section \"\(c.section ?? "")\" has no label") }
    let all = try interpret(raw.cells)
    guard !all.fields.isEmpty else { throw bad("it holds no values") }
    let parts = title.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    let (service, account) = parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty ? (parts[0], parts[1]) : (title, "default")
    return VaultItem(service: service, account: account, kind: "static", meta: nil, description: raw.notes, level: .server,
                     secret: SecretValue(fields: all.fields, lists: all.lists))
}
