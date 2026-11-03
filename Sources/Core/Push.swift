import Foundation

// Push (ADR-0010): a personal Mac makes a Server hold exactly its `server`-level Secrets.
// The personal Mac sends the whole desired set — every record with its values — through
// the stdin of ONE `ssh <host> mytokens put --stdin`; the Server converges its store to
// it. Declaring the set rather than sending steps makes a re-run change nothing, and the
// values travel only in the pipe: never argv, the environment, a file or printed output.

/// One Secret as it travels to a Server: the whole record, values included.
/// The wire format is private to this file — both ends of the pipe live here.
private struct PushedSecret: Codable, Equatable {
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
}

private struct PushPayload: Codable { var secrets: [PushedSecret] }

/// Runs one command on another Mac over SSH, feeding it `stdin`. Tests use a fake that
/// records what it was given; the real one runs `/usr/bin/ssh`.
protocol Remote {
    func run(host: String, command: String, stdin: Data) throws -> CommandResult
}

/// The command `push` runs on the Server. A non-interactive SSH shell may not have
/// `~/.local/bin` (where the installer links `mytokens`) on its PATH, so it adds it.
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

/// `push <host>`, on a personal Mac: send every `server`-level Secret to the Server and
/// relay what it reports (names only — the Server never prints a value).
func push(to host: String, from store: SecretStore, via remote: Remote) -> CommandResult {
    guard !host.isEmpty, !host.hasPrefix("-") else {
        return CommandResult(stdout: "", stderr: "push needs a host name (got \"\(host)\")\n", exitCode: 64)
    }
    do {
        let records = try store.list()
            .filter { $0.level == .server }
            .sorted { ($0.service, $0.account) < ($1.service, $1.account) }
        let secrets = try records.compactMap { r in
            try store.get(service: r.service, account: r.account).map { PushedSecret(r, $0) }
        }
        let payload = try JSONEncoder().encode(PushPayload(secrets: secrets))
        let r = try remote.run(host: host, command: remotePutCommand, stdin: payload)
        guard r.exitCode == 0 else {
            return CommandResult(stdout: r.stdout, stderr: "push to \(host) failed:\n" + r.stderr, exitCode: 1)
        }
        return CommandResult(stdout: r.stdout, stderr: r.stderr, exitCode: 0)
    } catch {
        return CommandResult(stdout: "", stderr: "\(error)\n", exitCode: 1)
    }
}

/// `put --stdin`, on a Server: converge the store to the pushed set. Adds and updates
/// each pushed Secret (marking it pushed), removes every earlier-pushed Secret the set no
/// longer holds, and never touches a Secret entered on the Server itself. Prints what it
/// changed by name, or `no changes`. Validates the whole set before writing anything.
func receivePush(_ input: Data, into store: SecretStore) -> CommandResult {
    func fail(_ s: String) -> CommandResult { CommandResult(stdout: "", stderr: s, exitCode: 1) }
    guard let payload = try? JSONDecoder().decode(PushPayload.self, from: input) else {
        return fail("put --stdin: input is not a push payload; nothing stored\n")
    }
    let incoming = payload.secrets
    if let bad = incoming.first(where: { $0.level != Level.server.rawValue }) {
        return fail("put --stdin: \(bad.name) is not 'server'-level; nothing stored\n")
    }
    if let bad = incoming.first(where: { $0.fields.isEmpty || $0.fields.contains { $0.value.isEmpty } }) {
        return fail("put --stdin: \(bad.name) has an empty value; nothing stored\n")
    }
    if Set(incoming.map(\.name)).count != incoming.count {
        return fail("put --stdin: a secret is listed twice; nothing stored\n")
    }
    do {
        let here = try store.list()
        func record(_ s: PushedSecret) -> SecretRecord? {
            here.first { $0.service == s.service && $0.account == s.account }
        }
        var lines: [String] = []
        for s in incoming {
            let existing = record(s)
            if let existing, !existing.pushed {
                lines.append("kept \(s.name): entered on this server, not pushed")
                continue
            }
            if let existing, let value = try store.get(service: s.service, account: s.account),
               PushedSecret(existing, value) == s {
                continue   // already exactly this
            }
            try store.upsert(service: s.service, account: s.account, secret: s.secret, kind: s.kind,
                             meta: s.meta.flatMap(JSONUtil.parse), description: s.description,
                             level: .server, pushed: true)
            lines.append("\(existing == nil ? "added" : "updated") \(s.name)")
        }
        let wanted = Set(incoming.map(\.name))
        let gone = here.filter { $0.pushed && !wanted.contains("\($0.service)/\($0.account)") }
        for r in gone.sorted(by: { ($0.service, $0.account) < ($1.service, $1.account) }) {
            _ = try store.delete(service: r.service, account: r.account)
            lines.append("removed \(r.service)/\(r.account)")
        }
        let changed = lines.contains { !$0.hasPrefix("kept ") }
        if !changed { lines.append("no changes") }
        return CommandResult(stdout: lines.joined(separator: "\n") + "\n", stderr: "", exitCode: 0)
    } catch {
        return fail("\(error)\n")
    }
}
