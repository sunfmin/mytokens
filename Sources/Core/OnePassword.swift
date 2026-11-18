import CryptoKit
import Foundation

// The 1Password vault target (ADR-0022): one more place Sync brings the `server`-level Secrets,
// for machines that are not Macs running mytokens (Linux boxes, CI) and read the vault with a
// 1Password service account. One-way: nothing is Adopted from a vault. The vault list is kept
// like the Server list (ADR-0015). Values reach `op` only on its stdin; the service account
// token only as OP_SERVICE_ACCOUNT_TOKEN in the `op` child's environment.

/// The service and account of the vault list's keychain item (a `ServerList` of vault names).
/// A Secret cannot take the service: `put` and `rm` refuse it.
let vaultListService = "mytokens.onepassword-vaults"

/// The Secret that holds the service account token that writes to the vaults. `personal`: it is
/// never exported anywhere, whatever level it is given.
let onePasswordTokenService = "1password-service-account"

/// A vault list that lives in memory only: `Dependencies`' default, as for the other state;
/// `.live` uses the keychain's.
final class MemoryNameList: ServerList {
    var names: [String] = []
    init() {}
    func read() throws -> [String] { Array(Set(names)).sorted() }
    func write(_ hosts: [String]) throws { names = Array(Set(hosts)).sorted() }
}

/// How `op` is run. Tests use a fake `op` on PATH through `OPCommand(path:)`.
protocol OnePasswordCLI {
    func run(_ args: [String], stdin: Data, token: String) throws -> CommandResult
}

/// Runs `op <args>` with `token` as OP_SERVICE_ACCOUNT_TOKEN in the child's environment only.
struct OPCommand: OnePasswordCLI {
    var path: String? = nil      // PATH for the child; nil keeps this process's

    func run(_ args: [String], stdin: Data, token: String) throws -> CommandResult {
        var env = ProcessInfo.processInfo.environment
        if let path { env["PATH"] = path }
        env["OP_SERVICE_ACCOUNT_TOKEN"] = token
        return try runProcess("/usr/bin/env", ["op"] + args, environment: env, stdin: stdin)
    }
}

/// Runs a process, feeding it `stdin`, draining both outputs while writing so a chatty child
/// can't deadlock the pipe.
func runProcess(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                stdin: Data) throws -> CommandResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = arguments
    if let environment { p.environment = environment }
    let input = Pipe(), output = Pipe(), errors = Pipe()
    p.standardInput = input
    p.standardOutput = output
    p.standardError = errors
    try p.run()
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

/// The key a vault's status is kept under in Background Sync's state, apart from the hosts'.
func vaultStatusKey(_ vault: String) -> String { "1password:\(vault)" }

/// An item already in the vault, from `op item list`.
private struct ListedItem: Decodable {
    var id: String
    var title: String
    var tags: [String]?
    /// Only an item with a digest tag is the sync's own; a `mytokens`-tagged one without is hand-made.
    var digest: String? { tags?.first { $0.hasPrefix(vaultDigestPrefix) }.map { String($0.dropFirst(vaultDigestPrefix.count)) } }
}

let vaultTokenMissing = """
    this Mac has no 1Password service account token; store it (it stays on this Mac):
      mytokens put \(onePasswordTokenService) --description "1Password service account that writes the mytokens vault"

    """

/// The items the `server`-level Secrets want, by title. Two Secrets with one title fail, naming both.
private func wantedVaultItems(_ store: SecretStore, _ target: SyncTarget) -> Result<[String: VaultItem], StepFailure> {
    var wanted: [String: VaultItem] = [:]
    var owners: [String: String] = [:]
    do {
        if target == .serverLevel {
            for r in try store.list().sorted(by: { ($0.service, $0.account) < ($1.service, $1.account) })
            where r.level == .server && r.service != onePasswordTokenService {
                guard let s = try store.get(service: r.service, account: r.account) else { continue }
                let title = vaultItemTitle(service: r.service, account: r.account)
                let name = "\(r.service)/\(r.account)"
                if let other = owners[title] {
                    return .failure(StepFailure(step: "name the vault items",
                        why: "\(other) and \(name) would both be the vault item \"\(title)\"; rename one (nothing was written)\n"))
                }
                owners[title] = name
                wanted[title] = VaultItem(service: r.service, account: r.account, kind: r.kind, meta: r.meta, description: r.description,
                                          level: r.level, secret: s)
            }
        }
    } catch {
        return .failure(StepFailure(step: "read the secrets", why: "\(error)\n"))
    }
    return .success(wanted)
}

/// Sync one 1Password vault so it holds exactly this Mac's `server`-level Secrets (or none, for
/// `.nothing`): one item per Secret, titled `<service>` (`<service>.<account>` for a non-default account).
/// An item is its own only with a `mytokens-digest-*` tag: those whose Secret is gone or no longer
/// `server`-level are archived. A `mytokens`-tagged item without a digest whose title is wanted is
/// taken over (edited in place); one whose title is not wanted, and every other item, is never touched. Nothing is written when nothing changed. A failure names its step.
func syncVault(_ vault: String, store: SecretStore, cli: OnePasswordCLI, holding target: SyncTarget = .serverLevel)
    -> Result<[String], StepFailure> {
    // The service account token: a Secret on this Mac, never exported.
    let token: String
    do {
        guard let value = try store.get(service: onePasswordTokenService, account: "default")?.loneValue, !value.isEmpty else {
            return .failure(StepFailure(step: "read the service account token", why: vaultTokenMissing))
        }
        token = value
    } catch {
        return .failure(StepFailure(step: "read the service account token", why: "\(error)\n"))
    }
    let wanted: [String: VaultItem]
    switch wantedVaultItems(store, target) {
    case .success(let w): wanted = w
    case .failure(let f): return .failure(f)
    }

    func op(_ step: String, _ args: [String], stdin: Data = Data()) throws -> CommandResult {
        let r: CommandResult
        do { r = try cli.run(args, stdin: stdin, token: token) } catch {
            throw StepFailure(step: step, why: "\(error)\n")
        }
        guard r.exitCode == 0 else { throw StepFailure(step: step, why: r.stderr.isEmpty ? r.stdout : r.stderr) }
        return r
    }

    do {
        let listed = try op("list the vault", ["item", "list", "--vault", vault, "--tags", vaultItemTag, "--format", "json"])
        guard let items = try? JSONDecoder().decode([ListedItem].self, from: Data(listed.stdout.utf8)) else {
            throw StepFailure(step: "list the vault", why: "op did not answer with the vault's items\n")
        }
        var lines: [String] = []
        var held: Set<String> = []
        let mine = items.filter { $0.digest != nil }.sorted(by: { ($0.title, $0.id) < ($1.title, $1.id) })
        let handMade = items.filter { $0.digest == nil && $0.tags?.contains(vaultItemTag) == true }
            .sorted(by: { ($0.title, $0.id) < ($1.title, $1.id) })
        for item in mine {
            if let want = wanted[item.title], !held.contains(item.title) {
                held.insert(item.title)
                if item.digest != want.digest {
                    _ = try op("write the vault", ["item", "edit", item.id, "--vault", vault],
                               stdin: want.template(forEdit: true))
                    lines.append("updated \(item.title)")
                }
            } else {                      // its Secret is gone, or a second item of the same title
                _ = try op("write the vault", ["item", "delete", item.id, "--vault", vault, "--archive"])
                lines.append("removed \(item.title)")
            }
        }
        for item in handMade {            // taken over in place: same id, same category
            guard let want = wanted[item.title], !held.contains(item.title) else { continue }
            held.insert(item.title)
            _ = try op("write the vault", ["item", "edit", item.id, "--vault", vault],
                       stdin: want.template(forEdit: true))
            lines.append("took over \(item.title)")
        }
        for title in wanted.keys.sorted() where !held.contains(title) {
            _ = try op("write the vault", ["item", "create", "--vault", vault],
                       stdin: wanted[title]!.template())
            lines.append("added \(title)")
        }
        return .success(lines.isEmpty ? ["no changes"] : lines)
    } catch let failure as StepFailure {
        return .failure(failure)
    } catch {
        return .failure(StepFailure(step: "write the vault", why: "\(error)\n"))
    }
}

/// How many `mytokens`-tagged items the vault holds that the sync does not own and no wanted Secret
/// matches (hand-copied ones it leaves alone). nil when that can't be found out (no token, `op` failed).
private func leftAloneCount(_ vault: String, store: SecretStore, cli: OnePasswordCLI) -> Int? {
    guard let token = (try? store.get(service: onePasswordTokenService, account: "default"))?.loneValue, !token.isEmpty,
          case .success(let wanted) = wantedVaultItems(store, .serverLevel),
          let r = try? cli.run(["item", "list", "--vault", vault, "--tags", vaultItemTag, "--format", "json"], stdin: Data(), token: token),
          r.exitCode == 0, let items = try? JSONDecoder().decode([ListedItem].self, from: Data(r.stdout.utf8)) else { return nil }
    return items.filter { $0.digest == nil && $0.tags?.contains(vaultItemTag) == true && wanted[$0.title] == nil }.count
}

/// The line that fixes a vault's failure, where it is known.
func vaultFixLine(vault: String, _ failure: StepFailure) -> String {
    if failure.step == "read the service account token" {
        return "mytokens put \(onePasswordTokenService) --description \"1Password service account that writes the mytokens vault\""
    }
    if failure.why.contains("keychain is locked") { return "unlock this Mac's keychain (log in once)" }
    return "check the service account can write \(shellWord(vault)) (op vault get \(shellWord(vault))), then: mytokens onepassword add \(shellWord(vault))"
}

private func validVault(_ v: String) -> Bool { !v.isEmpty && !v.hasPrefix("-") }

/// `onepassword add|rm|list`, on a personal Mac. `add` makes the vault hold the `server`-level
/// Secrets first and records it only when that worked; `rm` makes it hold none, then forgets it.
func runOnePassword(_ verb: String, _ vaults: [String], store: SecretStore, deps: Dependencies) -> CommandResult {
    func fail(_ s: String, _ code: Int32 = 1) -> CommandResult { CommandResult(stdout: "", stderr: s, exitCode: code) }
    func lines(_ l: [String]) -> String { l.map { $0 + "\n" }.joined() }
    let list = deps.vaults
    do {
        let listed = try list.read()
        switch (verb, vaults.count) {
        case ("list", 0):
            if listed.isEmpty { return fail("no 1Password vaults on the vault list\n", 0) }
            let statuses = deps.syncState.statuses()
            return CommandResult(stdout: lines(listed.map { vault in
                let status = statuses[vaultStatusKey(vault)]
                var row = "\(vault)\t\(describeStatus(status))"
                if let n = leftAloneCount(vault, store: store, cli: deps.onepassword), n > 0 {
                    row += " — \(n) hand-made item\(n == 1 ? "" : "s") tagged \(vaultItemTag) left alone"
                }
                if let status, status.isFailing, let step = status.failedStep {
                    row += " — fix: " + vaultFixLine(vault: vault, StepFailure(step: step, why: status.failedError ?? ""))
                }
                return row
            }), stderr: "", exitCode: 0)
        case ("add", 1):
            guard validVault(vaults[0]) else { return fail("onepassword add needs a vault name (got \"\(vaults[0])\")\n", 64) }
            switch syncVault(vaults[0], store: store, cli: deps.onepassword) {
            case .failure(let f):
                return fail("onepassword add \(vaults[0]) failed to \(f.step); it is not added to the vault list:\n" + f.why)
            case .success(var did):
                deps.syncState.update(vaultStatusKey(vaults[0])) { $0.succeeded(at: deps.now()) }
                if listed.contains(vaults[0]) { did.append("\(vaults[0]) is on the vault list") } else {
                    try list.write(listed + [vaults[0]])
                    did.append("added \(vaults[0]) to the vault list")
                }
                return CommandResult(stdout: lines(did), stderr: "", exitCode: 0)
            }
        case ("rm", 1):
            guard listed.contains(vaults[0]) else { return fail("\(vaults[0]) is not on the vault list\n") }
            switch syncVault(vaults[0], store: store, cli: deps.onepassword, holding: .nothing) {
            case .failure(let f):
                return fail("onepassword rm \(vaults[0]) failed to \(f.step); it stays on the vault list:\n" + f.why)
            case .success(let did):
                try list.write(listed.filter { $0 != vaults[0] })
                deps.syncState.forget(vaultStatusKey(vaults[0]))
                return CommandResult(stdout: lines(did + ["removed \(vaults[0]) from the vault list"]), stderr: "", exitCode: 0)
            }
        default:
            return fail("usage: mytokens onepassword add <vault> | rm <vault> | list\n", 64)
        }
    } catch {
        return fail("\(error)\n")
    }
}
