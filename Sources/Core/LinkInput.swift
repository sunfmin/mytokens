import Foundation
import Network
import Security

/// Where the one-time link is served: the host's tailnet address, and — when the
/// host's tailscale hands out a certificate — the TLS identity and the name it is for.
struct LinkEndpoint {
    /// The address the listener binds to; it listens on no other interface.
    var bindAddress: String
    /// HTTPS: the certificate's identity and the DNS name the link names. nil ⇒ plain HTTP.
    var tls: (identity: SecIdentity, hostName: String)?
    /// Why the link is plain HTTP, said when the link is printed; nil for HTTPS.
    var plainHTTPReason: String?
}

/// Collects a Secret's values through a one-time link (ADR-0010): serves one page on
/// the tailnet address only, prints the link, and waits until it is used or expires.
/// The values go from the browser straight into this process — never to the agent.
struct LinkSecretInput: SecretInput {
    /// Finds where to serve; nil ⇒ no tailnet here, so `.unavailable`.
    var endpoint: () -> LinkEndpoint?
    /// Says the link to whoever runs `put` (live: stderr). Where it goes next is theirs.
    var announce: (String) -> Void
    var lifetime: TimeInterval = OneTimeLink.lifetime

    func promptForSecret(service: String, account: String, description: String?, fields: [Field]) -> PromptResult {
        guard let endpoint = endpoint() else { return .unavailable }
        let link = OneTimeLink(service: service, account: account, description: description, fields: fields,
                               expires: Date().addingTimeInterval(lifetime))
        let server: LinkServer
        do {
            server = try LinkServer(link: link, bindAddress: endpoint.bindAddress, identity: endpoint.tls?.identity)
        } catch {
            announce("mytokens: could not serve a link on \(endpoint.bindAddress): \(error)\n")
            return .unavailable
        }
        let url: String
        if let tls = endpoint.tls {
            url = "https://\(tls.hostName):\(server.port)\(link.path)"
        } else {
            url = "http://\(endpoint.bindAddress):\(server.port)\(link.path)"
        }
        var message = "mytokens: open this link to enter the secret for \(service) / \(account) "
            + "(it works once, within \(Int(lifetime / 60)) minutes):\n  \(url)\n"
        if let reason = endpoint.plainHTTPReason {
            message += "  (plain HTTP on the tailnet, which WireGuard encrypts: \(reason))\n"
        }
        announce(message)
        guard let values = server.wait() else { return .expired }
        return .entered(values)
    }

    /// The live link: the tailnet address from `tailscale`, stderr for the link.
    static var live: LinkSecretInput {
        LinkSecretInput(endpoint: { Tailnet.endpoint() },
                        announce: { FileHandle.standardError.write(Data($0.utf8)) })
    }
}

enum LinkServerError: Error, CustomStringConvertible {
    case notReady(String)
    var description: String {
        switch self { case .notReady(let why): return "listener did not start: \(why)" }
    }
}

/// One `NWListener` on one address, serving one `OneTimeLink`. It closes after the
/// submission or at expiry; every request is answered on a serial queue, so the link's
/// state changes in one place.
final class LinkServer {
    private let queue = DispatchQueue(label: "mytokens.link")
    private var link: OneTimeLink
    private let listener: NWListener
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var submitted: [String: String]?
    private var closed = false
    private let done = DispatchSemaphore(value: 0)
    private(set) var port: UInt16 = 0

    init(link: OneTimeLink, bindAddress: String, identity: SecIdentity?) throws {
        self.link = link
        let params: NWParameters
        if let identity, let secIdentity = sec_identity_create(identity) {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            params = .tcp
        }
        // Bind to the one address only: the listener is not on any other interface.
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindAddress), port: .any)
        params.allowLocalEndpointReuse = false
        listener = try NWListener(using: params)

        let ready = DispatchSemaphore(value: 0)
        var failure: String?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure = "\(error)"; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, failure == nil, let port = listener.port?.rawValue else {
            listener.cancel()
            throw LinkServerError.notReady(failure ?? "timed out")
        }
        self.port = port
        listener.stateUpdateHandler = nil
    }

    /// Blocks until the link is used (its values) or expires (nil); the listener is closed either way.
    func wait() -> [String: String]? {
        let seconds = max(0, link.expires.timeIntervalSinceNow)
        _ = done.wait(timeout: .now() + seconds)
        return queue.sync {
            close()
            return submitted
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !closed else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled: self.connections[ObjectIdentifier(connection)] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        receive(connection, Data())
    }

    private func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: HTTPRequest.maxBytes) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil { connection.cancel() } else { self.receive(connection, buffer) }
            case .invalid:
                self.respond(connection, .text(400, "Bad Request", "Bad request."), submitted: nil)
            case .complete(let request):
                let (response, submitted) = self.closed
                    ? (HTTPResponse.text(410, "Gone", "This link is closed."), nil)
                    : self.link.handle(request, now: Date())
                self.respond(connection, response, submitted: submitted)
            }
        }
    }

    private func respond(_ connection: NWConnection, _ response: HTTPResponse, submitted: [String: String]?) {
        if let submitted {
            self.submitted = submitted
            listener.cancel()        // no new connections once the link is used
        }
        connection.send(content: response.bytes, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            if submitted != nil { self?.done.signal() }
        })
    }

    /// On the queue: stop listening and drop every open connection.
    private func close() {
        guard !closed else { return }
        closed = true
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }
}

/// The host's tailnet, through the `tailscale` CLI: its IPv4 address, and a certificate
/// for its tailnet name where the host's tailscale allows this user `tailscale cert`.
enum Tailnet {
    static func endpoint() -> LinkEndpoint? {
        guard let tailscale = executable(),
              let ipOut = run(tailscale, ["ip", "-4"], timeout: 10), ipOut.status == 0,
              let ip = String(decoding: ipOut.stdout, as: UTF8.self)
                .split(whereSeparator: \.isNewline).first.map(String.init),
              !ip.isEmpty
        else { return nil }

        guard let name = dnsName(tailscale) else {
            return LinkEndpoint(bindAddress: ip, tls: nil, plainHTTPReason: "this host has no tailnet DNS name")
        }
        switch certificate(tailscale, name) {
        case .success(let identity):
            return LinkEndpoint(bindAddress: ip, tls: (identity, name), plainHTTPReason: nil)
        case .failure(let reason):
            return LinkEndpoint(bindAddress: ip, tls: nil, plainHTTPReason: reason.message)
        }
    }

    struct Refusal: Error { var message: String }

    /// `Self.DNSName` from `tailscale status --json`, without its trailing dot.
    private static func dnsName(_ tailscale: String) -> String? {
        guard let out = run(tailscale, ["status", "--json"], timeout: 10), out.status == 0,
              let json = try? JSONSerialization.jsonObject(with: out.stdout) as? [String: Any],
              let me = json["Self"] as? [String: Any],
              let name = me["DNSName"] as? String, !name.isEmpty
        else { return nil }
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }

    /// `tailscale cert` into a private temporary directory, read as an in-memory identity.
    private static func certificate(_ tailscale: String, _ name: String) -> Result<SecIdentity, Refusal> {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mytokens-link-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return .failure(Refusal(message: "could not make a temporary directory: \(error)"))
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let cert = dir.appendingPathComponent("cert.pem").path
        let key = dir.appendingPathComponent("key.pem").path
        guard let out = run(tailscale, ["cert", "--cert-file", cert, "--key-file", key, name], timeout: 90) else {
            return .failure(Refusal(message: "tailscale cert did not finish"))
        }
        guard out.status == 0 else {
            let said = String(decoding: out.stderr + out.stdout, as: UTF8.self)
                .split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(out.status)"
            return .failure(Refusal(message: "tailscale cert: \(said)"))
        }
        return TLSIdentity.load(certPEM: cert, keyPEM: key).mapError { Refusal(message: $0.message) }
    }

    /// The `tailscale` CLI: on PATH, or where Homebrew or the app put it.
    private static func executable() -> String? {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = path.map { $0 + "/tailscale" } + [
            "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", home + "/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// A PEM certificate and key as an in-memory TLS identity: `/usr/bin/openssl` bundles
/// them into PKCS#12 under a one-off password, imported memory-only — never into a keychain.
enum TLSIdentity {
    static func load(certPEM: String, keyPEM: String) -> Result<SecIdentity, Tailnet.Refusal> {
        guard #available(macOS 15.0, *) else {
            return .failure(.init(message: "an in-memory TLS identity needs macOS 15"))
        }
        let password = OneTimeLink.freshToken()
        guard let out = run("/usr/bin/openssl",
                            ["pkcs12", "-export", "-in", certPEM, "-inkey", keyPEM, "-passout", "env:MYTOKENS_P12"],
                            timeout: 30, environment: ["MYTOKENS_P12": password]),
              out.status == 0, !out.stdout.isEmpty
        else { return .failure(.init(message: "openssl could not bundle the certificate")) }

        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: password,
                                      kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(out.stdout as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String]
        else { return .failure(.init(message: "could not import the certificate (\(status))")) }
        return .success(identity as! SecIdentity)
    }
}

/// Runs a tool to completion or until `timeout`, capturing its output.
private func run(_ path: String, _ args: [String], timeout: TimeInterval,
                 environment: [String: String] = [:]) -> (status: Int32, stdout: Data, stderr: Data)? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    if !environment.isEmpty {
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
    }
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do { try process.run() } catch { return nil }

    var stdout = Data(), stderr = Data()
    let group = DispatchGroup()
    for (pipe, isOut) in [(out, true), (err, false)] {
        group.enter()
        DispatchQueue.global().async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if isOut { stdout = data } else { stderr = data }
            group.leave()
        }
    }
    guard exited.wait(timeout: .now() + timeout) == .success else {
        process.terminate()
        return nil
    }
    group.wait()
    return (process.terminationStatus, stdout, stderr)
}
