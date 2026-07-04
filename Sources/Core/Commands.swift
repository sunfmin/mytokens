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

/// Semantic reads over the parsed args (ADR-0007). The `account` default lives
/// here once — `add`/`get`/`rm` must agree on it or a Secret becomes unfindable.
extension ParsedArgs {
    /// The command's target Service (first positional), or nil if none was given.
    var service: String? { positionals.first }
    /// The account, defaulting to "default" — the single source of that default.
    var account: String { flags["account"] ?? "default" }
    /// A flag's value, treating a present-but-empty flag as absent.
    func flag(_ name: String) -> String? { flags[name].flatMap { $0.isEmpty ? nil : $0 } }
    /// Whether a bare presence flag (e.g. `--json`) was given.
    func present(_ name: String) -> Bool { flags[name] != nil }
}

/// Split a comma-separated flag value (e.g. `--fields`/`--show`) into trimmed,
/// non-empty entries. Field labels may contain spaces, just not commas (ADR-0005).
private func splitCSV(_ s: String) -> [String] {
    s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// True iff `s` is a legal POSIX shell variable name: `[A-Za-z_][A-Za-z0-9_]*`.
/// A Profile's Field labels must satisfy this so `env` can emit `export <label>=…`.
private func isValidEnvName(_ s: String) -> Bool {
    guard let first = s.unicodeScalars.first else { return false }
    let isAlpha: (Unicode.Scalar) -> Bool = { ("A"..."Z").contains($0) || ("a"..."z").contains($0) }
    let isDigit: (Unicode.Scalar) -> Bool = { ("0"..."9").contains($0) }
    guard isAlpha(first) || first == "_" else { return false }
    return s.unicodeScalars.allSatisfy { isAlpha($0) || isDigit($0) || $0 == "_" }
}

/// POSIX single-quote a value so `eval "$(mytokens env …)"` sets it verbatim and
/// cannot inject shell: wrap in `'…'`, and rewrite each embedded `'` as `'\''`
/// (close-quote, escaped literal quote, reopen-quote). Handles spaces, `$`,
/// backticks, newlines — everything (ADR-0008).
private func shellSingleQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
    case "env": return runEnv(rest, deps)
    case "list": return runList(rest, deps)
    case "rm": return runRm(rest, deps)
    case "selftest": return runSelftest()
    default: return usage()
    }
}

private func usage() -> CommandResult {
    fail("""
    usage:
      mytokens add <service> [--account <label>] [--kind static|parent|profile] [--meta <json>]
                             [--description "<text>"]
                             [--fields "<Label>","<Label>" [--show "<Label>",…]]
      mytokens get <service> [--account <label>] [--field "<Label>" | --json]
      mytokens env <service> [--account <label>]
      mytokens list
      mytokens rm  <service> [--account <label>]

    """, 64)
}

private func runAdd(_ argv: [String], _ deps: Dependencies) -> CommandResult {
    let args = parseArgs(argv)
    guard let service = args.service else { return usage() }
    let account = args.account
    let kind = args.flags["kind"] ?? "static"
    guard kind == "static" || kind == "parent" || kind == "profile" else {
        return fail("--kind must be 'static', 'parent', or 'profile'\n", 64)
    }

    // Agent's purpose note (ADR-0006). Optional here; SKILL.md mandates the agent set it.
    let description = args.flag("description")

    // Multi-field shape (ADR-0005). No --fields ⇒ the single bare-value path.
    let fieldLabels = args.flags["fields"].map(splitCSV) ?? []
    let showLabels = Set(args.flags["show"].map(splitCSV) ?? [])
    guard fieldLabels.isEmpty || kind != "parent" else {
        return fail("--kind parent cannot be combined with --fields (a Parent token is a single value)\n", 64)
    }
    if let unknown = showLabels.first(where: { !fieldLabels.contains($0) }) {
        return fail("--show \"\(unknown)\" is not one of --fields\n", 64)
    }
    // A Profile is a bundle of env vars, so it requires --fields and every label
    // must be a legal shell variable name — validated here so `env` can render
    // `export <label>=…` unconditionally (ADR-0008). Checked before prompting.
    if kind == "profile" {
        guard !fieldLabels.isEmpty else {
            return fail("--kind profile requires --fields (the environment-variable names)\n", 64)
        }
        if let bad = fieldLabels.first(where: { !isValidEnvName($0) }) {
            return fail("--fields \"\(bad)\" is not a valid environment-variable name (need [A-Za-z_][A-Za-z0-9_]*)\n", 64)
        }
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

    guard let values = deps.input.promptForSecret(service: service, account: account,
                                                  description: description, fields: promptFields) else {
        return fail("cancelled; nothing stored\n", 1)
    }
    // Every field is required (ADR-0005) — the popup enforces it; double-check here.
    for field in promptFields {
        guard let v = values[field.label], !v.isEmpty else { return fail("empty value; nothing stored\n", 1) }
    }

    // Assemble the Secret as ordered Fields; the store owns whether that persists as
    // a raw value or a JSON object (ADR-0005). No --fields ⇒ the lone unlabelled value.
    let secret = fieldLabels.isEmpty
        ? SecretValue(single: values[""] ?? "")
        : SecretValue(fields: fieldLabels.map { (label: $0, value: values[$0] ?? "") })

    do {
        try deps.store.upsert(service: service, account: account, secret: secret,
                              kind: kind, meta: meta, description: description)
        return ok("stored \(service)/\(account)\n")
    } catch {
        return fail("\(error)\n", 1)
    }
}

private func runGet(_ argv: [String], _ deps: Dependencies) -> CommandResult {
    let args = parseArgs(argv)
    guard let service = args.service else { return usage() }
    let account = args.account
    let field = args.flag("field")
    let wantJSON = args.present("json")
    do {
        guard let secret = try deps.store.get(service: service, account: account) else {
            return fail("no secret for \(service)/\(account)\n", 1)
        }

        // Lone unlabelled value: --field is meaningless, --json is ignored (ADR-0002).
        guard secret.isLabelled else {
            if field != nil { return fail("\(service)/\(account) has no fields\n", 1) }
            return CommandResult(stdout: secret.fields[0].value, stderr: "", exitCode: 0)  // exact value, no newline
        }

        if let field {
            guard let v = secret.value(forField: field) else {
                return fail("\(service)/\(account) has no field '\(field)'; fields: \(secret.labels.joined(separator: ", "))\n", 1)
            }
            return CommandResult(stdout: v, stderr: "", exitCode: 0)  // one field's raw value
        }
        if wantJSON {
            guard let json = secret.compactJSON() else { return fail("failed to encode fields\n", 1) }
            return CommandResult(stdout: json, stderr: "", exitCode: 0)  // whole object, compact
        }
        if let only = secret.loneValue {
            return CommandResult(stdout: only, stderr: "", exitCode: 0)  // degenerate 1-field ⇒ bare value
        }
        return fail("\(service)/\(account) has fields: \(secret.labels.joined(separator: ", ")) — use --field <label> or --json\n", 1)
    } catch {
        return fail("\(error)\n", 1)
    }
}

// `env` renders a Profile as shell `export` lines for `eval` (ADR-0008). The kind
// lives on the record (list) while the values live on the SecretValue (get), and no
// single store call returns both — so read the kind from `list()`, then the values
// from `get()`. Profile-only is enforced by the `kind` marker (the source of truth),
// not by inferring it from label shape. Stays on ADR-0002's stdout side (no exec).
private func runEnv(_ argv: [String], _ deps: Dependencies) -> CommandResult {
    let args = parseArgs(argv)
    guard let service = args.service else { return usage() }
    let account = args.account
    do {
        guard let record = try deps.store.list().first(where: { $0.service == service && $0.account == account }) else {
            return fail("no secret for \(service)/\(account)\n", 1)
        }
        guard record.kind == "profile" else {
            return fail("\(service)/\(account) is kind '\(record.kind)', not a Profile — `env` only renders Profiles\n", 1)
        }
        guard let secret = try deps.store.get(service: service, account: account) else {
            return fail("no secret for \(service)/\(account)\n", 1)   // vanished between list and get
        }
        // Emit one `export NAME='VALUE'` per Field, in stored order. Labels were
        // validated at `add` time; re-check as defense against a corrupt item.
        var lines: [String] = []
        for field in secret.fields {
            guard isValidEnvName(field.label) else {
                return fail("\(service)/\(account) field '\(field.label)' is not a valid environment-variable name\n", 1)
            }
            lines.append("export \(field.label)=\(shellSingleQuote(field.value))")
        }
        return ok(lines.joined(separator: "\n") + "\n")
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
            if let description = r.description { line += "  — " + description }
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
    guard let service = args.service else { return usage() }
    let account = args.account
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
// Runs two legs: a lone unlabelled value (raw round-trip, ADR-0002) and a
// multi-field Secret (the labelled JSON encode/decode that lives in the store,
// ADR-0005). Provides its own values, so no popup is involved.
private func runSelftest() -> CommandResult {
    let store = KeychainSecretStore()
    let service = "mytokens.selftest"
    _ = try? store.delete(service: service, account: "single")   // clear any leftover
    _ = try? store.delete(service: service, account: "multi")
    do {
        // Single-value leg: raw value in, raw value out.
        try store.upsert(service: service, account: "single", secret: SecretValue(single: "SELFTEST-OK"),
                         kind: "static", meta: ["probe": true], description: nil)
        let single = try store.get(service: service, account: "single")?.loneValue == "SELFTEST-OK"

        // Multi-field leg: Fields in, Fields back, ordered schema preserved.
        try store.upsert(service: service, account: "multi",
                         secret: SecretValue(fields: [(label: "A", value: "a"), (label: "B", value: "b")]),
                         kind: "static", meta: nil, description: nil)
        let got = try store.get(service: service, account: "multi")
        let fieldsBack = got?.value(forField: "A") == "a" && got?.value(forField: "B") == "b"
        let schemaBack = try store.list().first { $0.service == service && $0.account == "multi" }?.fields == ["A", "B"]

        let listed = try store.list().contains { $0.service == service && $0.account == "single" }
        let deleted = try store.delete(service: service, account: "single") && (try store.delete(service: service, account: "multi"))
        let gone = try store.get(service: service, account: "single") == nil && (try store.get(service: service, account: "multi")) == nil

        let pass = single && fieldsBack && schemaBack && listed && deleted && gone
        let report = "single=\(single) · fields=\(fieldsBack) · schema=\(schemaBack) · list=\(listed) · delete=\(deleted) · gone=\(gone)\n"
        return pass ? ok(report + "SELFTEST PASS\n") : fail(report + "SELFTEST FAIL\n", 1)
    } catch {
        return fail("SELFTEST FAIL: \(error)\n", 1)
    }
}
