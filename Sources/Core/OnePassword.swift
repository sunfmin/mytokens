import CryptoKit
import Foundation

// The 1Password vault target (ADR-0022): one more place Sync brings the `server`-level Secrets,
// for machines that are not Macs running mytokens (Linux boxes, CI) and read the vault with a
// 1Password service account. Two-way (mytokens#13): an item made in the vault is Adopted. The vault list is kept
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

/// The origin mark of a Secret Adopted from a vault (ADR-0018 for a Server): never a host name.
func vaultOriginKey(_ vault: String) -> String { "1password:\(vault)" }

/// What this Mac remembers of one vault between syncs (kept in the vault's status, per Mac).
/// `items`: for each item the sync owns, by id, the `version` 1Password listed after the sync last
/// wrote or adopted it (nil when the write did not say) and the digest of what it then held; a
/// listed version that differs means someone changed it in 1Password. `created` and `createdIds`:
/// when each title was created and the id `create` answered with, because 1Password lists a new item
/// only ~10 s later: a sync inside that window treats the title as held (it must not create it twice)
/// and keeps what it knows of the id until the item is listed. (`createdIds` is optional: state
/// written before it existed still reads.)
struct VaultMemory: Codable, Equatable {
    struct Item: Codable, Equatable { var version: Int?; var digest: String }
    var items: [String: Item] = [:]
    var created: [String: Double] = [:]
    var createdIds: [String: String]? = nil
}

final class VaultMemoryRef {
    var value = VaultMemory()
    init(_ value: VaultMemory = VaultMemory()) { self.value = value }
}

/// Which side a vault conflict is settled for (`onepassword keep`, mytokens#16): `mac` writes the
/// Mac's Secret over the item, `onePassword` Adopts the item over the Secret.
enum VaultSide: String { case mac, onePassword = "1password" }

/// One conflict to settle in a sync: the item titled `title`, for `side`.
struct VaultKeep: Equatable { var title: String; var side: VaultSide }

/// The prefix of the line a sync says when it settled the conflict `keep` asked for.
let vaultKeptPrefix = "kept "

/// What a conflict line says to end it.
func vaultKeepHint(_ vault: String, _ title: String) -> String {
    "settle it: mytokens onepassword keep \(shellWord(vault)) \(shellWord(title)) mac|1password"
}

/// How long after a `create` a title is not created again.
private let vaultListingLag: TimeInterval = 120

/// An item already in the vault, from `op item list`.
private struct ListedItem: Decodable {
    var id: String
    var title: String
    var tags: [String]?
    var version: Int?
    var category: String?
    /// Only an item with a digest tag is the sync's own; any other is hand-made.
    var digest: String? { tags?.first { $0.hasPrefix(vaultDigestPrefix) }.map { String($0.dropFirst(vaultDigestPrefix.count)) } }
}

/// How many writes the service account may still make: the smallest `remaining` of its token's write
/// limit and its account's read/write limit (`op service-account ratelimit`, mytokens#14: 100 an
/// hour per token, 1000 a day per account). nil when `op` does not say: then nothing is held back.
private func remainingWrites(_ json: String) -> Int? {
    guard let rows = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else { return nil }
    let left = rows.compactMap { row -> Int? in
        guard let remaining = row["remaining"] as? Int else { return nil }
        let action = row["action"] as? String
        return action == "write" || action == "read_write" ? remaining : nil
    }
    return left.min()
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

/// Sync one 1Password vault with this Mac, both ways (ADR-0022). The Mac is the home:
///
/// - Every `server`-level Secret is one item, titled `<service>` (`<service>.<account>` for a
///   non-default account). An item is the sync's own with a `mytokens-digest-*` tag. A Secret that is
///   gone or no longer `server`-level has its item archived.
/// - An item changed in 1Password (its listed `version` is not the one remembered, and its content
///   differs) while the Secret is unchanged is Adopted into the Secret; changed on both sides, it is a
///   **conflict** and neither side changes. Only the Mac changed: written to the vault.
/// - An item the sync did not make whose title names no Secret is Adopted: stored as a `server`-level
///   Secret and rewritten in mytokens' format. One that cannot be mapped without loss is reported.
///   One whose title names a Secret here that the sync does not own is a conflict — except a
///   `mytokens`-tagged item with a wanted title, taken over in place (the hand copies of 2026-11-07).
/// - An item deleted in the vault whose Secret is `server`-level is written again.
///
/// Lines starting `conflict` or `not adopted` are things the human decides; they come back on every
/// sync until resolved. Nothing is written when nothing changed, and an item never twice for one
/// change. A write the service account's budget does not cover (`op service-account ratelimit`) is
/// left for the next run, with a line `deferred <title>`. A failure names its step.
///
/// `keep` settles one conflict (`onepassword keep`, mytokens#16): the item titled so, if it is in
/// conflict, takes the Mac's Secret (`mac`) or is Adopted over it (`1password`), with a line
/// starting `kept `. A title not in conflict is not touched by it.
func syncVault(_ vault: String, store: SecretStore, cli: OnePasswordCLI, holding target: SyncTarget = .serverLevel,
               now: Date = Date(), memory: VaultMemoryRef = VaultMemoryRef(), keep: VaultKeep? = nil) -> Result<[String], StepFailure> {
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
    /// `id` and `version` from what a write printed, when it printed the item.
    func written(_ r: CommandResult) -> (id: String?, version: Int?) {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8))) as? [String: Any] else { return (nil, nil) }
        return (o["id"] as? String, o["version"] as? Int)
    }
    var writesLeft: Int?
    var budgetAsked = false
    /// Whether one more write fits the service account's budget (asked of `op` once, at the first write).
    func canWrite() throws -> Bool {
        if !budgetAsked {
            budgetAsked = true
            let r = try? cli.run(["service-account", "ratelimit", "--format", "json"], stdin: Data(), token: token)
            if let r, r.exitCode == 0 { writesLeft = remainingWrites(r.stdout) }
        }
        guard let left = writesLeft else { return true }
        if left <= 0 { return false }
        writesLeft = left - 1
        return true
    }
    func edit(_ item: ListedItem, _ vi: VaultItem) throws -> Int? {
        written(try op("write the vault", ["item", "edit", item.id, "--vault", vault, "--format", "json"],
                       stdin: vi.template(forEdit: true, loginIds: item.category == "LOGIN"))).version
    }
    func fetch(_ item: ListedItem) throws -> Data {
        Data(try op("read the vault", ["item", "get", item.id, "--vault", vault, "--format", "json"]).stdout.utf8)
    }

    do {
        let listed = try op("list the vault", ["item", "list", "--vault", vault, "--format", "json"])
        guard let items = try? JSONDecoder().decode([ListedItem].self, from: Data(listed.stdout.utf8)) else {
            throw StepFailure(step: "list the vault", why: "op did not answer with the vault's items\n")
        }
        let records = try store.list()
        var byTitle: [String: SecretRecord] = [:]
        for r in records.sorted(by: { ($0.service, $0.account) < ($1.service, $1.account) }) {
            let t = vaultItemTitle(service: r.service, account: r.account)
            if byTitle[t] == nil { byTitle[t] = r }
        }
        let originKey = vaultOriginKey(vault)
        var lines: [String] = []
        var held: Set<String> = []
        let order: (ListedItem, ListedItem) -> Bool = { ($0.title, $0.id) < ($1.title, $1.id) }
        let mine = items.filter { $0.digest != nil }.sorted(by: order)
        let others = items.filter { $0.digest == nil }.sorted(by: order)
        memory.value.created = memory.value.created.filter { now.timeIntervalSince1970 - $0.value < vaultListingLag }
        var known: [String: VaultMemory.Item] = [:]

        /// The Secret as the vault now says it, kept as the Mac's own (level, name from the Secret).
        func normalized(_ seen: VaultItem, like want: VaultItem) -> VaultItem {
            var v = seen
            v.service = want.service; v.account = want.account; v.level = .server
            return v
        }
        func adoptIntoSecret(_ v: VaultItem, marks: SyncMarks) throws {
            try store.upsert(service: v.service, account: v.account, secret: v.secret, kind: v.kind,
                             meta: v.meta.flatMap(JSONUtil.parse), description: v.description, level: .server, marks: marks)
        }

        let deferral = "the service account has no writes left this hour (op service-account ratelimit); the next run goes on"
        /// Writes `vi` over `item` when the budget allows: its new version, or `.deferred` (a line says so).
        enum Written { case version(Int?), deferred }
        func tryEdit(_ item: ListedItem, _ vi: VaultItem, _ title: String) throws -> Written {
            guard try canWrite() else { lines.append("deferred \(title): \(deferral)"); return .deferred }
            return .version(try edit(item, vi))
        }

        for item in mine {
            guard let want = wanted[item.title], !held.contains(item.title) else {
                // its Secret is gone, or a second item of the same title
                held.insert(item.title)
                guard try canWrite() else {
                    lines.append("deferred removing \(item.title): \(deferral)")
                    if let memo = memory.value.items[item.id] { known[item.id] = memo }
                    continue
                }
                _ = try op("write the vault", ["item", "delete", item.id, "--vault", vault, "--archive"])
                lines.append("removed \(item.title)")
                continue
            }
            held.insert(item.title)
            let tagged = item.digest!
            let memo = memory.value.items[item.id]
            let last = memo?.digest ?? tagged
            let sameVersion = memo?.version != nil && memo?.version == item.version
            let wantDigest = want.digest
            func record(_ version: Int?, _ digest: String) { known[item.id] = VaultMemory.Item(version: version, digest: digest) }
            /// Writes `vi` over the item, remembers it and says `line`; a write the budget does not cover keeps what was known.
            func write(_ vi: VaultItem, _ line: String) throws {
                switch try tryEdit(item, vi, item.title) {
                case .version(let v): record(v, vi.digest); lines.append(line)
                case .deferred: if let memo { known[item.id] = memo }
                }
            }
            if sameVersion {                       // nothing changed in 1Password: no read
                if wantDigest == last { record(item.version, last) } else { try write(want, "updated \(item.title)") }
                continue
            }
            let seen = (try? decodeVaultItem(try fetch(item))).map { normalized($0, like: want) }
            guard let seen else {                   // the item can no longer be read back: the Mac is the home
                try write(want, "updated \(item.title)")
                continue
            }
            if seen.digest == wantDigest {          // same content on both sides
                if tagged != wantDigest { try write(want, "updated \(item.title)") }
                else { record(item.version, wantDigest) }
            } else if wantDigest == last {          // changed in 1Password only: Adopt it
                try adoptIntoSecret(seen, marks: byTitle[item.title]?.marks ?? SyncMarks())
                try write(seen, "adopted \(item.title) (changed in 1Password)")
            } else if seen.digest == last {         // changed on the Mac only
                try write(want, "updated \(item.title)")
            } else if keep == VaultKeep(title: item.title, side: .mac) {
                try write(want, "\(vaultKeptPrefix)this Mac's \(item.title) (written over 1Password's)")
            } else if keep == VaultKeep(title: item.title, side: .onePassword) {
                try adoptIntoSecret(seen, marks: byTitle[item.title]?.marks ?? SyncMarks())
                try write(seen, "\(vaultKeptPrefix)1Password's \(item.title) (adopted over this Mac's)")
            } else {
                lines.append("conflict \(item.title): changed in 1Password and on this Mac since the last sync; neither changed; "
                             + vaultKeepHint(vault, item.title))
                if let memo { known[item.id] = memo }
            }
        }

        if target == .serverLevel {
            for item in others {
                let t = item.title
                if held.contains(t) {
                    lines.append("not adopted \(t): another item has the same title")
                    continue
                }
                if let want = wanted[t], item.tags?.contains(vaultItemTag) == true {   // a hand copy: taken over in place
                    held.insert(t)
                    if case .version(let v) = try tryEdit(item, want, t) {
                        known[item.id] = VaultMemory.Item(version: v, digest: want.digest)
                        lines.append("took over \(t)")
                    }
                    continue
                }
                if let rec = byTitle[t] {
                    if rec.origin == originKey, rec.level == .server,
                       let s = try store.get(service: rec.service, account: rec.account) {
                        // An adoption cut short (stored here, the item never rewritten): finish it.
                        held.insert(t)
                        let vi = VaultItem(service: rec.service, account: rec.account, kind: rec.kind, meta: rec.meta,
                                           description: rec.description, level: .server, secret: s)
                        if case .version(let v) = try tryEdit(item, vi, t) {
                            known[item.id] = VaultMemory.Item(version: v, digest: vi.digest)
                            lines.append("adopted \(t)")
                        }
                    } else if keep?.title == t, keep?.side == .mac {
                        // the Mac's Secret wins: a server-level one is written over the item, any other has it archived
                        held.insert(t)
                        if let want = wanted[t] {
                            if case .version(let v) = try tryEdit(item, want, t) {
                                known[item.id] = VaultMemory.Item(version: v, digest: want.digest)
                                lines.append("\(vaultKeptPrefix)this Mac's \(t) (written over 1Password's)")
                            }
                        } else if try canWrite() {
                            _ = try op("write the vault", ["item", "delete", item.id, "--vault", vault, "--archive"])
                            lines.append("\(vaultKeptPrefix)this Mac's \(t) (\(rec.level.rawValue)-level, so not in the vault: 1Password's archived)")
                        } else {
                            lines.append("deferred \(t): \(deferral)")
                        }
                    } else if keep?.title == t, keep?.side == .onePassword {
                        // 1Password's item wins: Adopted over the Secret, which becomes server-level and the sync's
                        let decoded: VaultItem
                        do { decoded = try decodeHandMadeItem(try fetch(item), title: t) } catch let e as VaultDecodeError {
                            lines.append("not adopted \(t): \(e.description)")
                            continue
                        }
                        held.insert(t)
                        var vi = decoded
                        vi.service = rec.service; vi.account = rec.account; vi.level = .server
                        try adoptIntoSecret(vi, marks: SyncMarks(origin: originKey))
                        if case .version(let v) = try tryEdit(item, vi, t) {
                            known[item.id] = VaultMemory.Item(version: v, digest: vi.digest)
                            lines.append("\(vaultKeptPrefix)1Password's \(t) (adopted over this Mac's)")
                        }
                    } else {
                        held.insert(t)      // neither changed: no second item of the title is created either
                        lines.append("conflict \(t): a Secret of that name is on this Mac and the sync does not own it; neither changed; "
                                     + vaultKeepHint(vault, t))
                    }
                    continue
                }
                let decoded: VaultItem
                do { decoded = try decodeHandMadeItem(try fetch(item), title: t) } catch let e as VaultDecodeError {
                    lines.append("not adopted \(t): \(e.description)")
                    continue
                }
                held.insert(t)
                let note = adoptionNote(host: "1Password vault \(vault)", on: now)
                var vi = decoded
                vi.description = decoded.description.map { "\(note)\n\($0)" } ?? note
                try adoptIntoSecret(vi, marks: SyncMarks(origin: originKey))
                // stored here either way: a deferred rewrite is finished by the next run (the cut-short case above)
                if case .version(let v) = try tryEdit(item, vi, t) {
                    known[item.id] = VaultMemory.Item(version: v, digest: vi.digest)
                    lines.append("adopted \(t)")
                }
            }
        }

        // `create` answers with the id at once, 1Password lists the item ~10 s later: a title created
        // inside that window counts as held, and what is known of its id is kept until it is listed.
        var createdIds = memory.value.createdIds ?? [:]
        createdIds = createdIds.filter { memory.value.created[$0.key] != nil }
        let listedIds = Set(items.map(\.id))
        for (title, id) in createdIds where !listedIds.contains(id) {
            held.insert(title)
            if known[id] == nil, let m = memory.value.items[id] { known[id] = m }
        }
        for title in wanted.keys.sorted() where !held.contains(title) {
            if memory.value.created[title] != nil { continue }
            guard try canWrite() else { lines.append("deferred \(title): \(deferral)"); continue }
            let w = written(try op("write the vault", ["item", "create", "--vault", vault, "--format", "json"],
                                   stdin: wanted[title]!.template()))
            memory.value.created[title] = now.timeIntervalSince1970
            if let id = w.id {
                known[id] = VaultMemory.Item(version: w.version, digest: wanted[title]!.digest)
                createdIds[title] = id
            }
            lines.append("added \(title)")
        }
        memory.value.createdIds = createdIds.isEmpty ? nil : createdIds
        memory.value.items = known
        return .success(lines.isEmpty ? ["no changes"] : lines)
    } catch let failure as StepFailure {
        return .failure(failure)
    } catch {
        return .failure(StepFailure(step: "write the vault", why: "\(error)\n"))
    }
}

/// The lines of a vault sync the human has to decide or know: conflicts, items not adopted, and
/// writes the service account's budget deferred to the next run.
func vaultAttention(_ lines: [String]) -> [String]? {
    let a = lines.filter { $0.hasPrefix("conflict ") || $0.hasPrefix("not adopted ") || $0.hasPrefix("deferred ") }
    return a.isEmpty ? nil : a
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

/// `onepassword add|rm|list|keep`, on a personal Mac. `add` makes the vault hold the `server`-level
/// Secrets first and records it only when that worked; `rm` makes it hold none, then forgets it.
/// `keep <vault> <title> mac|1password` settles one conflict the last sync reported (mytokens#16).
func runOnePassword(_ verb: String, _ vaults: [String], store: SecretStore, deps: Dependencies) -> CommandResult {
    func fail(_ s: String, _ code: Int32 = 1) -> CommandResult { CommandResult(stdout: "", stderr: s, exitCode: code) }
    func lines(_ l: [String]) -> String { l.map { $0 + "\n" }.joined() }
    let list = deps.vaults
    /// Syncs `vault` as Background Sync would and records its status: what it did, or why it failed.
    /// Call it holding the run lock.
    func syncRecorded(_ vault: String, keep: VaultKeep? = nil) -> Result<[String], StepFailure> {
        let memory = VaultMemoryRef(deps.syncState.statuses()[vaultStatusKey(vault)]?.vaultMemory ?? VaultMemory())
        let r = syncVault(vault, store: store, cli: deps.onepassword, now: deps.now(), memory: memory, keep: keep)
        if case .success(let did) = r {
            deps.syncState.update(vaultStatusKey(vault)) { $0.succeeded(at: deps.now()); $0.vaultMemory = memory.value; $0.attention = vaultAttention(did) }
        }
        return r
    }
    do {
        let listed = try list.read()
        switch (verb, vaults.count) {
        case ("list", 0):
            if listed.isEmpty { return fail("no 1Password vaults on the vault list\n", 0) }
            let statuses = deps.syncState.statuses()
            return CommandResult(stdout: lines(listed.map { vault in
                let status = statuses[vaultStatusKey(vault)]
                var row = "\(vault)\t\(describeStatus(status))"
                for a in status?.attention ?? [] { row += "\n  \(a)" }
                if let status, status.isFailing, let step = status.failedStep {
                    row += " — fix: " + vaultFixLine(vault: vault, StepFailure(step: step, why: status.failedError ?? ""))
                }
                return row
            }), stderr: "", exitCode: 0)
        case ("add", 1):
            guard validVault(vaults[0]) else { return fail("onepassword add needs a vault name (got \"\(vaults[0])\")\n", 64) }
            // Two syncs of one vault never run at once: this waits for a Background Sync run in progress.
            var result = fail("onepassword add did not run\n")
            deps.syncState.exclusively {
                switch syncRecorded(vaults[0]) {
                case .failure(let f):
                    result = fail("onepassword add \(vaults[0]) failed to \(f.step); it is not added to the vault list:\n" + f.why)
                case .success(var did):
                    do {
                        if listed.contains(vaults[0]) { did.append("\(vaults[0]) is on the vault list") } else {
                            try list.write(listed + [vaults[0]])
                            did.append("added \(vaults[0]) to the vault list")
                        }
                        result = CommandResult(stdout: lines(did), stderr: "", exitCode: 0)
                    } catch { result = fail("\(error)\n") }
                }
            }
            return result
        case ("rm", 1):
            guard listed.contains(vaults[0]) else { return fail("\(vaults[0]) is not on the vault list\n") }
            var result = fail("onepassword rm did not run\n")
            deps.syncState.exclusively {
                switch syncVault(vaults[0], store: store, cli: deps.onepassword, holding: .nothing) {
                case .failure(let f):
                    result = fail("onepassword rm \(vaults[0]) failed to \(f.step); it stays on the vault list:\n" + f.why)
                case .success(let did):
                    if did.contains(where: { $0.hasPrefix("deferred ") }) {
                        result = fail("onepassword rm \(vaults[0]): the write budget ran out before the vault was emptied; it stays on the vault list (run it again later):\n" + lines(did))
                        return
                    }
                    do {
                        try list.write(listed.filter { $0 != vaults[0] })
                        deps.syncState.forget(vaultStatusKey(vaults[0]))
                        result = CommandResult(stdout: lines(did + ["removed \(vaults[0]) from the vault list"]), stderr: "", exitCode: 0)
                    } catch { result = fail("\(error)\n") }
                }
            }
            return result
        case ("keep", 3):
            let (vault, title) = (vaults[0], vaults[1])
            guard let side = VaultSide(rawValue: vaults[2]) else {
                return fail("onepassword keep takes mac or 1password as the side to keep (got \"\(vaults[2])\")\n", 64)
            }
            guard listed.contains(vault) else { return fail("\(vault) is not on the vault list\n") }
            let noConflict = "no conflict on \(title) in the vault \(vault)"
            // Refused, touching nothing, unless the last sync of the vault reported this conflict.
            let attention = deps.syncState.statuses()[vaultStatusKey(vault)]?.attention ?? []
            guard attention.contains(where: { $0.hasPrefix("conflict \(title): ") }) else {
                return fail("\(noConflict) (onepassword list shows the conflicts); nothing kept\n")
            }
            var result = fail("onepassword keep did not run\n")
            deps.syncState.exclusively {
                switch syncRecorded(vault, keep: VaultKeep(title: title, side: side)) {
                case .failure(let f):
                    result = fail("onepassword keep \(vault) \(title) failed to \(f.step); neither side changed:\n" + f.why)
                case .success(let did):
                    // the sync ran either way; only a `kept` line means the conflict is settled
                    if did.contains(where: { $0.hasPrefix(vaultKeptPrefix) }) {
                        result = CommandResult(stdout: lines(did), stderr: "", exitCode: 0)
                    } else {
                        result = CommandResult(stdout: lines(did), stderr: "\(noConflict) settled by this run; nothing kept\n", exitCode: 1)
                    }
                }
            }
            return result
        default:
            return fail("usage: mytokens onepassword add <vault> | rm <vault> | list | keep <vault> <title> mac|1password\n", 64)
        }
    } catch {
        return fail("\(error)\n")
    }
}
