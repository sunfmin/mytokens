import Foundation

// A **miss**: a job on a Server asked for a Secret the Server does not hold. Instead of
// only failing, the Server says why, names the line to run on a personal Mac, and tells
// the human once an hour through Bark, using its own `bark` Secret (sunfmin/control#744).

/// The one place a miss's words live, so the printed message and the push agree.
struct Miss {
    var service: String
    var account: String
    var host: String

    /// The line to run on a personal Mac: an existing Secret only changes its level, a new
    /// one is entered there (ADR-0010).
    var putLine: String {
        var words = ["mytokens", "put", service]
        if account != "default" { words += ["--account", account] }
        return (words + ["--level", "server"]).map(shellWord).joined(separator: " ")
    }
    var syncLine: String { "mytokens sync \(shellWord(host))" }
    var name: String { "\(service)/\(account)" }

    var message: String {
        """
        no secret for \(name): it is not on this server (\(host)).
        A server holds only server-level secrets, synced from your personal Macs.
        On a personal Mac, run:
          \(putLine)
        (an existing secret: only its level changes; a new one: you enter it there),
        and the next sync brings it here — to bring it now, on that Mac: \(syncLine)

        """
    }

    var pushTitle: String { "mytokens: \(host) lacks \(name)" }
    var pushBody: String { "On a personal Mac run: \(putLine) — then \(syncLine)" }
}

/// Where a Bark push goes, read from the Server's `bark` Secret: a lone value that is a
/// device key (sent to api.day.app) or a whole push URL (`https://api.day.app/<key>`, or a
/// self-hosted server's), or labelled Fields naming the key and, optionally, the server.
enum BarkTarget {
    static let service = "bark"
    static let defaultServer = "https://api.day.app"

    static func url(from secret: SecretValue) -> URL? {
        func field(_ names: Set<String>) -> String? {
            secret.fields.first { names.contains($0.label.lowercased().filter { $0.isLetter }) }?.value
        }
        let raw: String?
        if !secret.isLabelled {
            raw = secret.fields.first?.value
        } else if let key = field(["devicekey", "key"]) {
            let server = field(["server"]) ?? defaultServer
            raw = server.hasSuffix("/") ? server + key : server + "/" + key
        } else {
            raw = field(["url"]) ?? secret.loneValue
        }
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix("https://") || raw.hasPrefix("http://") { return URL(string: raw) }
        guard raw.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return URL(string: defaultServer + "/" + raw)
    }
}

/// Sends one Bark push. Tests record; `.live` posts over HTTPS.
protocol BarkTransport {
    func push(to url: URL, title: String, body: String) throws
}

/// What a build without a live transport sends: nothing.
struct NoBarkTransport: BarkTransport {
    func push(to url: URL, title: String, body: String) throws {}
}

struct BarkError: Error, CustomStringConvertible {
    var description: String
}

/// POSTs `{title, body, group}` as JSON to the push URL, waiting at most 10 s.
struct HTTPBarkTransport: BarkTransport {
    func push(to url: URL, title: String, body: String) throws {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["title": title, "body": body, "group": "mytokens"])
        let done = DispatchSemaphore(value: 0)
        var failure: String?
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error { failure = error.localizedDescription }
            else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                failure = "HTTP \(http.statusCode)"
            }
            done.signal()
        }.resume()
        if done.wait(timeout: .now() + 12) == .timedOut { throw BarkError(description: "timed out") }
        if let failure { throw BarkError(description: failure) }
    }
}

/// When each Secret's miss was last pushed, so a Server pushes at most once per Secret per
/// hour however many jobs ask.
protocol PushLedger {
    /// Records `now` for `key` and answers true when no push for it was recorded within the
    /// last `interval`; answers false, recording nothing, otherwise. Check and record are
    /// one step, so jobs missing at once push once.
    func claim(_ key: String, now: Date, interval: TimeInterval) -> Bool
}

/// In-memory ledger: the default outside `.live`, and what tests read.
final class MemoryPushLedger: PushLedger {
    private(set) var pushed: [String: Date] = [:]
    init() {}
    func claim(_ key: String, now: Date, interval: TimeInterval) -> Bool {
        if let last = pushed[key], now.timeIntervalSince(last) < interval { return false }
        pushed[key] = now
        return true
    }
}

/// Real ledger: `~/Library/Application Support/mytokens/miss-pushes.json`, `{key: epoch
/// seconds}`, read and rewritten under an exclusive lock on the file beside it. A ledger it
/// cannot open or read never stops the push: the hourly limit is a courtesy.
struct FilePushLedger: PushLedger {
    var url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/mytokens/miss-pushes.json")

    func claim(_ key: String, now: Date, interval: TimeInterval) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = open(url.path + ".lock", O_RDWR | O_CREAT | O_EXLOCK, 0o600)
        defer { if lock >= 0 { close(lock) } }
        var entries: [String: Double] = [:]
        if let data = FileManager.default.contents(atPath: url.path),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Double] {
            entries = decoded
        }
        if let last = entries[key], now.timeIntervalSince1970 - last < interval { return false }
        entries[key] = now.timeIntervalSince1970
        entries = entries.filter { now.timeIntervalSince1970 - $0.value < interval }   // forget the stale
        if let data = try? JSONSerialization.data(withJSONObject: entries, options: .sortedKeys) {
            try? data.write(to: url, options: .atomic)
        }
        return true
    }
}

/// This Mac's short name, as `sync <host>` would reach it (`mini-jp`, not `mini-jp.local`).
func currentHostName() -> String {
    let full = ProcessInfo.processInfo.hostName
    return full.split(separator: ".").first.map(String.init) ?? full
}

/// The tellings of a miss: the message for stderr, plus one line saying whether Bark was told.
func reportMiss(service: String, account: String, store: SecretStore, deps: Dependencies) -> CommandResult {
    let miss = Miss(service: service, account: account, host: deps.hostName())
    var text = miss.message
    let bark = (try? store.get(service: BarkTarget.service, account: "default")).flatMap { $0 }
    if service == BarkTarget.service && account == "default" {
        // The bark Secret itself is the miss: nothing to push with.
    } else if let bark {
        if let url = BarkTarget.url(from: bark) {
            if deps.pushLedger.claim(miss.name, now: deps.now(), interval: 3600) {
                do {
                    try deps.bark.push(to: url, title: miss.pushTitle, body: miss.pushBody)
                    text += "Told you through Bark.\n"
                } catch {
                    text += "The Bark push failed (\(error)).\n"
                }
            } else {
                text += "Bark was told within the last hour; not pushed again.\n"
            }
        } else {
            text += "The bark secret here is not a device key or push URL; nothing pushed.\n"
        }
    }
    return CommandResult(stdout: "", stderr: text, exitCode: 1)
}
