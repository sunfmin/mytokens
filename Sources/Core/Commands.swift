import Foundation

/// The result of running a command: what to print and the exit code.
/// `stdout` is written verbatim (no added newline) so `get` emits exactly the value.
struct CommandResult {
    var stdout: String
    var stderr: String
    var exitCode: Int32
}

private func ok(_ s: String) -> CommandResult { CommandResult(stdout: s, stderr: "", exitCode: 0) }
private func fail(_ s: String, _ code: Int32) -> CommandResult { CommandResult(stdout: "", stderr: s, exitCode: code) }

/// The one injected seam. `.live` wires the real keychain + popup; tests pass fakes.
struct Dependencies {
    var store: SecretStore
    var input: SecretInput
    static var live: Dependencies { .init(store: KeychainSecretStore(), input: PopupSecretInput()) }
}

private struct ParsedArgs {
    var positionals: [String] = []
    var flags: [String: String] = [:]
}

/// Split a comma-separated flag value (e.g. `--fields`/`--show`) into trimmed,
/// non-empty entries. Field labels may contain spaces, just not commas (ADR-0005).
private func splitCSV(_ s: String) -> [String] {
    s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

private func parseArgs(_ argv: [String]) -> ParsedArgs {
    var result = ParsedArgs()
    var i = 0
    while i < argv.count {
        let token = argv[i]
        if token.hasPrefix("--") {
            let key = String(token.dropFirst(2))
            if i + 1 < argv.count && !argv[i + 1].hasPrefix("--") {
                result.flags[key] = argv[i + 1]
                i += 2
            } else {
                result.flags[key] = ""
                i += 1
            }
        } else {
            result.positionals.append(token)
            i += 1
        }
    }
    return result
}

/// Top-level dispatch. Pure over `Dependencies`, so tests drive it directly.
func runCommand(_ argv: [String], _ deps: Dependencies) -> CommandResult {
    guard let cmd = argv.first else { return usage() }
    let rest = Array(argv.dropFirst())
    switch cmd {
    case "add": return runAdd(rest, deps)
    case "get": return runGet(rest, deps)
    case "list": return runList(rest, deps)
    case "rm": return runRm(rest, deps)
    case "selftest": return runSelftest()
    default: return usage()
    }
}

private func usage() -> CommandResult {
    fail("""
    usage:
      mytokens add <service> [--account <label>] [--kind static|parent] [--meta <json>]
                             [--fields "<Label>","<Label>" [--show "<Label>",…]]
      mytokens get <service> [--account <label>] [--field "<Label>" | --json]
      mytokens list
      mytokens rm  <service> [--account <label>]

    """, 64)
}

private func runAdd(_ argv: [String], _ deps: Dependencies) -> CommandResult {
    let args = parseArgs(argv)
    guard let service = args.positionals.first else { return usage() }
    let account = args.flags["account"] ?? "default"
    let kind = args.flags["kind"] ?? "static"
    guard kind == "static" || kind == "parent" else {
        return fail("--kind must be 'static' or 'parent'\n", 64)
    }

    // Multi-field shape (ADR-0005). No --fields ⇒ the single bare-value path.
    let fieldLabels = args.flags["fields"].map(splitCSV) ?? []
    let showLabels = Set(args.flags["show"].map(splitCSV) ?? [])
    guard fieldLabels.isEmpty || kind != "parent" else {
        return fail("--kind parent cannot be combined with --fields (a Parent token is a single value)\n", 64)
    }
    if let unknown = showLabels.first(where: { !fieldLabels.contains($0) }) {
        return fail("--show \"\(unknown)\" is not one of --fields\n", 64)
    }

    // Validate metadata BEFORE prompting, so bad args don't pop a dialog.
    var meta: Any?
    if let raw = args.flags["meta"] {
        guard let parsed = JSONUtil.parse(raw) else { return fail("--meta must be valid JSON\n", 64) }
        meta = parsed
    }

    let promptFields = fieldLabels.isEmpty
        ? [Field(label: "", masked: true)]
        : fieldLabels.map { Field(label: $0, masked: !showLabels.contains($0)) }

    guard let values = deps.input.promptForSecret(service: service, account: account, fields: promptFields) else {
        return fail("cancelled; nothing stored\n", 1)
    }
    // Every field is required (ADR-0005) — the popup enforces it; double-check here.
    for field in promptFields {
        guard let v = values[field.label], !v.isEmpty else { return fail("empty value; nothing stored\n", 1) }
    }

    // 1 field ⇒ store the raw value (back-compat, ADR-0002); >1 ⇒ a JSON object,
    // with the ordered label schema recorded by the store.
    let storeValue: String
    let storeFields: [String]?
    if fieldLabels.isEmpty {
        storeValue = values[""] ?? ""
        storeFields = nil
    } else {
        var obj: [String: String] = [:]
        for label in fieldLabels { obj[label] = values[label] }
        guard let json = JSONUtil.compact(obj) else { return fail("failed to encode fields\n", 1) }
        storeValue = json
        storeFields = fieldLabels
    }

    do {
        try deps.store.upsert(service: service, account: account, value: storeValue,
                              kind: kind, meta: meta, fields: storeFields)
        return ok("stored \(service)/\(account)\n")
    } catch {
        return fail("\(error)\n", 1)
    }
}

private func runGet(_ argv: [String], _ deps: Dependencies) -> CommandResult {
    let args = parseArgs(argv)
    guard let service = args.positionals.first else { return usage() }
    let account = args.flags["account"] ?? "default"
    let field = args.flags["field"].flatMap { $0.isEmpty ? nil : $0 }
    let wantJSON = args.flags["json"] != nil
    do {
        guard let stored = try deps.store.get(service: service, account: account) else {
            return fail("no secret for \(service)/\(account)\n", 1)
        }

        // Single bare value: no field schema (ADR-0002 behavior, unchanged).
        guard let fields = stored.fields else {
            if field != nil { return fail("\(service)/\(account) has no fields\n", 1) }
            return CommandResult(stdout: stored.value, stderr: "", exitCode: 0)  // exact value, no newline
        }

        // Multi-field: the stored value is a JSON object {label: value}.
        guard let obj = JSONUtil.parse(stored.value) as? [String: Any] else {
            return fail("\(service)/\(account) is malformed\n", 1)
        }
        if let field {
            guard let v = obj[field] as? String else {
                return fail("\(service)/\(account) has no field '\(field)'; fields: \(fields.joined(separator: ", "))\n", 1)
            }
            return CommandResult(stdout: v, stderr: "", exitCode: 0)  // one field's raw value
        }
        if wantJSON {
            return CommandResult(stdout: stored.value, stderr: "", exitCode: 0)  // whole object, compact
        }
        if fields.count == 1, let only = obj[fields[0]] as? String {
            return CommandResult(stdout: only, stderr: "", exitCode: 0)  // degenerate 1-field ⇒ bare value
        }
        return fail("\(service)/\(account) has fields: \(fields.joined(separator: ", ")) — use --field <label> or --json\n", 1)
    } catch {
        return fail("\(error)\n", 1)
    }
}

private func runList(_ argv: [String], _ deps: Dependencies) -> CommandResult {
    do {
        let records = try deps.store.list().sorted { ($0.service, $0.account) < ($1.service, $1.account) }
        if records.isEmpty { return CommandResult(stdout: "", stderr: "no secrets stored\n", exitCode: 0) }
        let rows = records.map { r -> String in
            var line = "\(r.service)/\(r.account)\t\(r.kind)"
            if let fields = r.fields, !fields.isEmpty { line += "  fields: " + fields.joined(separator: ", ") }
            if let meta = r.meta { line += "  " + meta }
            return line
        }
        return ok(rows.joined(separator: "\n") + "\n")
    } catch {
        return fail("\(error)\n", 1)
    }
}

private func runRm(_ argv: [String], _ deps: Dependencies) -> CommandResult {
    let args = parseArgs(argv)
    guard let service = args.positionals.first else { return usage() }
    let account = args.flags["account"] ?? "default"
    do {
        if try deps.store.delete(service: service, account: account) {
            return ok("removed \(service)/\(account)\n")
        }
        return fail("no secret for \(service)/\(account)\n", 1)
    } catch {
        return fail("\(error)\n", 1)
    }
}

// Post-install sanity check (ADR-0003): exercises the REAL KeychainSecretStore
// end-to-end against the data-protection keychain — upsert, get, list, delete,
// and confirm-gone — proving the entitlement and the store code path both work.
// Provides its own value, so no popup is involved.
private func runSelftest() -> CommandResult {
    let store = KeychainSecretStore()
    let service = "mytokens.selftest", account = "selftest"
    _ = try? store.delete(service: service, account: account)  // clear any leftover
    do {
        try store.upsert(service: service, account: account, value: "SELFTEST-OK", kind: "static", meta: ["probe": true], fields: nil)
        let roundtripped = try store.get(service: service, account: account)?.value == "SELFTEST-OK"
        let listed = try store.list().contains { $0.service == service && $0.account == account }
        let deleted = try store.delete(service: service, account: account)
        let gone = try store.get(service: service, account: account) == nil
        let pass = roundtripped && listed && deleted && gone
        let report = "upsert+get=\(roundtripped) · list=\(listed) · delete=\(deleted) · gone=\(gone)\n"
        return pass ? ok(report + "SELFTEST PASS\n") : fail(report + "SELFTEST FAIL\n", 1)
    } catch {
        return fail("SELFTEST FAIL: \(error)\n", 1)
    }
}
