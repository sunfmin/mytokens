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
    private func content(forEdit: Bool) -> [String: Any] {
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
    func template(forEdit: Bool = false) -> Data {
        var item = content(forEdit: forEdit)
        item["tags"] = [vaultItemTag, vaultDigestPrefix + digest]
        return encode(item)
    }
}

/// Why an item is not a Secret.
struct VaultDecodeError: Error, CustomStringConvertible {
    var description: String
}

/// `op item get --format json` (or a template) → the Secret it holds: the inverse of `VaultItem.template`.
func decodeVaultItem(_ json: Data) throws -> VaultItem {
    func bad(_ why: String) -> VaultDecodeError { VaultDecodeError(description: why) }
    guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { throw bad("not a JSON object") }
    let all = (root["fields"] as? [[String: Any]]) ?? []
    func value(_ f: [String: Any]) -> String { (f["value"] as? String) ?? "" }
    func sectionLabel(_ f: [String: Any]) -> String? { (f["section"] as? [String: Any])?["label"] as? String }
    func label(_ f: [String: Any]) -> String { (f["label"] as? String) ?? "" }

    var metadata: [String: String] = [:]
    var top: [String: String] = [:]
    var records: [String: [(index: Int, record: [String: String])]] = [:]
    var sectionRecords: [String: [String: String]] = [:]     // section label → its record
    var description: String?
    for f in all {
        if f["purpose"] as? String == "NOTES" { description = value(f).isEmpty ? nil : value(f); continue }
        switch sectionLabel(f) {
        case vaultMetadataSection?: metadata[label(f)] = value(f)
        case let s?: sectionRecords[s, default: [:]][label(f)] = value(f)
        case nil: top[label(f)] = value(f)
        }
    }
    for (section, record) in sectionRecords {       // `<Label> [<i>]`: the last " [" opens the index
        guard section.hasSuffix("]"), let open = section.range(of: " [", options: .backwards),
              let i = Int(section[open.upperBound..<section.index(before: section.endIndex)]) else {
            throw bad("section \"\(section)\" is not \"<Label> [<i>]\"")
        }
        records[String(section[..<open.lowerBound]), default: []].append((i, record))
    }
    func need(_ name: String) throws -> String {
        guard let v = metadata[name] else { throw bad("no \"\(name)\" in the \(vaultMetadataSection) section") }
        return v
    }
    guard let level = Level(rawValue: try need("level")) else { throw bad("unknown level \"\(metadata["level"] ?? "")\"") }
    let secret: SecretValue
    if try need("shape") == "bare" {
        guard let v = top[vaultBareFieldLabel] else { throw bad("no \"\(vaultBareFieldLabel)\" field") }
        secret = SecretValue(single: v)
    } else {
        guard let order = JSONUtil.parse(try need("order")) as? [String] else { throw bad("\"order\" is not a JSON array of labels") }
        var fields: [(label: String, value: String)] = []
        var lists: Set<String> = []
        for label in order {
            if let rs = records[label] {
                let sorted = rs.sorted { $0.index < $1.index }.map(\.record)
                guard let text = JSONUtil.compact(sorted), let canonical = ListValue.canonical(text) else {
                    throw bad("list \"\(label)\" is not a list of records")
                }
                fields.append((label, canonical)); lists.insert(label)
            } else if let v = top[label] {
                fields.append((label, v))
            } else {
                throw bad("no field \"\(label)\"")
            }
        }
        secret = SecretValue(fields: fields, lists: lists)
    }
    return VaultItem(service: try need("service"), account: try need("account"), kind: try need("kind"),
                     meta: metadata["meta"], description: description, level: level, secret: secret)
}
