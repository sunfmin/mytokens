import Foundation

// Sync (ADR-0012, narrowing ADR-0010): a personal Mac and one Server brought into agreement,
// the personal Mac the home of every Secret on it. Two SSH runs, values only in their pipes
// (never argv, the environment, a file or printed output):
//
//   1. Adopt. `ssh <host> mytokens get --unpushed` writes every Secret entered on the Server
//      (no pushed mark) to ssh's stdout. The personal Mac stores each one it has no Secret
//      of the same name for, `server`-level, its Description noting where it came from. A
//      same-name Secret here is a conflict: neither side changes, since a Server must never
//      overwrite a Secret on the user's own Macs (the iCloud Keychain would carry it to all).
//   2. Push. `ssh <host> mytokens put --stdin` reads the whole desired set — every
//      `server`-level Secret here, the adopted ones named — and the Server converges to it.
//
// Declaring the set rather than sending steps makes a second sync change nothing.

/// One Secret as it travels between a personal Mac and a Server: the whole record, values
/// included. The wire format is private to this file — both ends of both pipes live here.
private struct WireSecret: Codable, Equatable {
    struct Field: Codable, Equatable { var label: String; var value: String }
    var service: String
    var account: String
    var kind: String
    var level: String
    var meta: String?          // compact, key-sorted JSON, as `SecretRecord.meta` holds it
    var description: String?
    var fields: [Field]        // a lone unlabelled value is one Field with the empty label

    init(_ record: SecretRecord, _ secret: SecretValue) {
        service = record.service
        account = record.account
        kind = record.kind
        level = record.level.rawValue
        meta = record.meta
        description = record.description
        fields = secret.fields.map { Field(label: $0.label, value: $0.value) }
    }

    var secret: SecretValue { SecretValue(fields: fields.map { (label: $0.label, value: $0.value) }) }
    var name: String { "\(service)/\(account)" }
    /// Same values, kind and meta: what a Secret *is*, apart from its note and level.
    func sameContent(_ other: WireSecret) -> Bool {
        fields == other.fields && kind == other.kind && meta == other.meta
    }
}

/// What both pipes carry. `adopt` (push direction only) names the Secrets the Server
/// entered itself and now hands to the personal Mac: those it marks pushed.
private struct WirePayload: Codable {
    var secrets: [WireSecret]
    var adopt: [String]?
}

/// Runs one command on another Mac over SSH, feeding it `stdin`. Tests use a fake that
/// plays the Server; the real one runs `/usr/bin/ssh`.
protocol Remote {
    func run(host: String, command: String, stdin: Data) throws -> CommandResult
}

/// The commands `sync` runs on the Server. A non-interactive SSH shell may not have
/// `~/.local/bin` (where the installer links `mytokens`) on its PATH, so they add it.
let remoteExportCommand = #"PATH="$HOME/.local/bin:$PATH" mytokens get --unpushed"#
let remotePutCommand = #"PATH="$HOME/.local/bin:$PATH" mytokens put --stdin"#

/// Real remote: `ssh -- <host> <command>`, the payload on ssh's stdin.
struct SSHRemote: Remote {
    func run(host: String, command: String, stdin: Data) throws -> CommandResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["--", host, command]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        try p.run()
        // Drain both outputs while writing, so a chatty remote can't deadlock the pipe.
        var out = Data(), err = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { out = output.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { err = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        try? input.fileHandleForWriting.write(contentsOf: stdin)
        try? input.fileHandleForWriting.close()
        p.waitUntilExit()
        group.wait()
        return CommandResult(stdout: String(decoding: out, as: UTF8.self),
                             stderr: String(decoding: err, as: UTF8.self),
                             exitCode: p.terminationStatus)
    }
}

/// The note an adopted Secret's Description gains: where it came from, and when.
func adoptionNote(host: String, on date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return "adopted from \(host) on \(f.string(from: date))"
}

private func byName(_ a: SecretRecord, _ b: SecretRecord) -> Bool { (a.service, a.account) < (b.service, b.account) }

/// `sync <host>`, on a personal Mac: adopt what was entered on the Server, then push.
/// Prints what changed by name — `adopted`, `added`, `updated`, `removed`, `conflict` —
/// or `no changes`. A conflict makes the exit status 1, after everything else is done.
func sync(with host: String, store: SecretStore, via remote: Remote, now: Date) -> CommandResult {
    guard !host.isEmpty, !host.hasPrefix("-") else {
        return CommandResult(stdout: "", stderr: "sync needs a host name (got \"\(host)\")\n", exitCode: 64)
    }
    var lines: [String] = []
    func failed(_ why: String) -> CommandResult {
        CommandResult(stdout: lines.map { $0 + "\n" }.joined(), stderr: "sync with \(host) failed:\n" + why, exitCode: 1)
    }
    do {
        // 1. Adopt.
        let exported = try remote.run(host: host, command: remoteExportCommand, stdin: Data())
        guard exported.exitCode == 0 else { return failed(exported.stderr) }
        guard let entered = try? JSONDecoder().decode(WirePayload.self, from: Data(exported.stdout.utf8)) else {
            return failed("\(host) did not answer with its secrets (is mytokens there up to date?)\n")
        }
        if let bad = entered.secrets.first(where: { $0.fields.isEmpty || $0.fields.contains { $0.value.isEmpty } }) {
            return failed("\(bad.name) on \(host) has an empty value; nothing adopted\n")
        }
        let here = try store.list()
        var adopt: [String] = [], conflicts: [String] = []
        for s in entered.secrets.sorted(by: { ($0.service, $0.account) < ($1.service, $1.account) }) {
            if let mine = here.first(where: { $0.service == s.service && $0.account == s.account }) {
                // An adoption cut short (stored here, the push never reached the Server) left
                // this Mac's copy server-level with the same content: finish it. Anything
                // else is a conflict, and neither side changes.
                if mine.level == .server, let value = try store.get(service: s.service, account: s.account),
                   WireSecret(mine, value).sameContent(s) {
                    adopt.append(s.name)
                    lines.append("adopted \(s.name)")
                } else {
                    conflicts.append("conflict \(s.name): entered on \(host) and also on this Mac; neither changed")
                }
                continue
            }
            let note = adoptionNote(host: host, on: now)
            let description = s.description.map { "\($0) (\(note))" } ?? note
            try store.upsert(service: s.service, account: s.account, secret: s.secret, kind: s.kind,
                             meta: s.meta.flatMap(JSONUtil.parse), description: description,
                             level: .server, pushed: false)
            adopt.append(s.name)
            lines.append("adopted \(s.name)")
        }

        // 2. Push.
        let records = try store.list().filter { $0.level == .server }.sorted(by: byName)
        let secrets = try records.compactMap { r in
            try store.get(service: r.service, account: r.account).map { WireSecret(r, $0) }
        }
        let payload = try JSONEncoder().encode(WirePayload(secrets: secrets, adopt: adopt))
        let pushed = try remote.run(host: host, command: remotePutCommand, stdin: payload)
        guard pushed.exitCode == 0 else { return failed(pushed.stderr) }
        lines += pushed.stdout.split(separator: "\n").map(String.init).filter { $0 != "no changes" }
        lines += conflicts
        if lines.isEmpty { lines.append("no changes") }
        return CommandResult(stdout: lines.map { $0 + "\n" }.joined(), stderr: pushed.stderr,
                             exitCode: conflicts.isEmpty ? 0 : 1)
    } catch {
        return failed("\(error)\n")
    }
}

/// `get --unpushed`, on a Server: write every Secret entered here (no pushed mark), values
/// included, for `sync` to adopt. Its stdout is the SSH pipe back to the personal Mac.
func exportUnpushed(from store: SecretStore) -> CommandResult {
    do {
        let records = try store.list().filter { !$0.pushed }.sorted(by: byName)
        let secrets = try records.compactMap { r in
            try store.get(service: r.service, account: r.account).map { WireSecret(r, $0) }
        }
        let data = try JSONEncoder().encode(WirePayload(secrets: secrets, adopt: nil))
        return CommandResult(stdout: String(decoding: data, as: UTF8.self), stderr: "", exitCode: 0)
    } catch {
        return CommandResult(stdout: "", stderr: "\(error)\n", exitCode: 1)
    }
}

/// `put --stdin`, on a Server: converge the store to the pushed set. Adds and updates each
/// pushed Secret (marking it pushed), marks the adopted ones pushed, removes every
/// earlier-pushed Secret the set no longer holds, and leaves any other Secret entered here
/// alone (an unadopted conflict). Prints what it added, updated or removed by name, or
/// `no changes`. Validates the whole set before writing anything.
func receivePush(_ input: Data, into store: SecretStore) -> CommandResult {
    func fail(_ s: String) -> CommandResult { CommandResult(stdout: "", stderr: s, exitCode: 1) }
    guard let payload = try? JSONDecoder().decode(WirePayload.self, from: input) else {
        return fail("put --stdin: input is not a sync payload; nothing stored\n")
    }
    let incoming = payload.secrets
    let adopt = Set(payload.adopt ?? [])
    if let bad = incoming.first(where: { $0.level != Level.server.rawValue }) {
        return fail("put --stdin: \(bad.name) is not 'server'-level; nothing stored\n")
    }
    if let bad = incoming.first(where: { $0.fields.isEmpty || $0.fields.contains { $0.value.isEmpty } }) {
        return fail("put --stdin: \(bad.name) has an empty value; nothing stored\n")
    }
    let wanted = Set(incoming.map(\.name))
    if wanted.count != incoming.count {
        return fail("put --stdin: a secret is listed twice; nothing stored\n")
    }
    if let bad = adopt.subtracting(wanted).sorted().first {
        return fail("put --stdin: \(bad) is adopted but not sent; nothing stored\n")
    }
    do {
        let here = try store.list()
        var lines: [String] = []
        for s in incoming {
            let existing = here.first { $0.service == s.service && $0.account == s.account }
            let adopting = existing.map { !$0.pushed && adopt.contains(s.name) } ?? false
            if let existing, !existing.pushed, !adopting { continue }   // entered here, not adopted
            if let existing, existing.pushed, let value = try store.get(service: s.service, account: s.account),
               WireSecret(existing, value) == s {
                continue   // already exactly this
            }
            try store.upsert(service: s.service, account: s.account, secret: s.secret, kind: s.kind,
                             meta: s.meta.flatMap(JSONUtil.parse), description: s.description,
                             level: .server, pushed: true)
            if !adopting { lines.append("\(existing == nil ? "added" : "updated") \(s.name)") }
        }
        let gone = here.filter { $0.pushed && !wanted.contains("\($0.service)/\($0.account)") }
        for r in gone.sorted(by: byName) {
            _ = try store.delete(service: r.service, account: r.account)
            lines.append("removed \(r.service)/\(r.account)")
        }
        if lines.isEmpty { lines.append("no changes") }
        return CommandResult(stdout: lines.joined(separator: "\n") + "\n", stderr: "", exitCode: 0)
    } catch {
        return fail("\(error)\n")
    }
}
