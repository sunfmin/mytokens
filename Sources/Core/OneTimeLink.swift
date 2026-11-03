import Foundation
import Security

/// The one-time link's rules (ADR-0010), with no sockets: a fresh 128-bit token, good
/// for one submission of the one Secret it was made for, until it expires. `LinkServer`
/// feeds it each HTTP request; it answers with the response to send and, once, the
/// submitted values. Pure over `now`, so tests drive the clock.
struct OneTimeLink {
    static let lifetime: TimeInterval = 10 * 60

    let service: String
    let account: String
    let description: String?
    let fields: [Field]
    let token: String
    let expires: Date
    private(set) var used = false

    init(service: String, account: String, description: String?, fields: [Field],
         expires: Date, token: String = OneTimeLink.freshToken()) {
        self.service = service
        self.account = account
        self.description = description
        self.fields = fields
        self.expires = expires
        self.token = token
    }

    /// The path the link serves: the token is the whole of it.
    var path: String { "/" + token }

    /// 16 random bytes from the system CSPRNG, as 32 lowercase hex digits.
    static func freshToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess,
                     "no system randomness")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// One request in, one response out; `submitted` carries label → value exactly once,
    /// for the first complete POST with the right token before expiry.
    mutating func handle(_ request: HTTPRequest, now: Date) -> (response: HTTPResponse, submitted: [String: String]?) {
        let requestPath = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        guard constantTimeEqual(requestPath, path) else { return (.text(404, "Not Found", "Not found."), nil) }
        guard !used else { return (.text(410, "Gone", "This link was already used. Nothing more is accepted."), nil) }
        guard now < expires else { return (.text(410, "Gone", "This link expired. Nothing was stored."), nil) }

        switch request.method {
        case "GET":
            return (.html(200, "OK", LinkPage.form(self, problem: nil)), nil)
        case "POST":
            let form = FormDecoding.decode(request.body)
            var values: [String: String] = [:]
            for (i, field) in fields.enumerated() {
                values[field.label] = form[LinkPage.inputName(i)] ?? ""
            }
            guard !fields.contains(where: { (values[$0.label] ?? "").isEmpty }) else {
                return (.html(400, "Bad Request", LinkPage.form(self, problem: "Every field needs a value.")), nil)
            }
            used = true
            return (.html(200, "OK", LinkPage.sent(self)), values)
        default:
            return (.text(405, "Method Not Allowed", "Method not allowed."), nil)
        }
    }

    /// Compare without an early exit, so response timing says nothing about the token.
    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

/// The parts of an HTTP/1.1 request the link reads.
struct HTTPRequest {
    var method: String
    var path: String
    var body: Data

    enum Parse { case incomplete, invalid, complete(HTTPRequest) }

    /// Requests larger than this are refused: the form is a few short Fields.
    static let maxBytes = 64 * 1024

    /// Parses bytes received so far: the head up to the blank line, then `Content-Length`
    /// bytes of body.
    static func parse(_ data: Data) -> Parse {
        guard data.count <= maxBytes else { return .invalid }
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[data.startIndex..<headEnd.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { return .invalid }
        var length = 0
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                guard let n = Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)), n >= 0 else {
                    return .invalid
                }
                length = n
            }
        }
        let body = data[headEnd.upperBound...]
        guard body.count >= length else { return .incomplete }
        return .complete(HTTPRequest(method: String(start[0]), path: String(start[1]), body: Data(body.prefix(length))))
    }
}

/// A complete response; the connection closes after it.
struct HTTPResponse {
    var status: Int
    var reason: String
    var contentType: String
    var body: String

    static func text(_ status: Int, _ reason: String, _ body: String) -> HTTPResponse {
        HTTPResponse(status: status, reason: reason, contentType: "text/plain; charset=utf-8", body: body + "\n")
    }
    static func html(_ status: Int, _ reason: String, _ body: String) -> HTTPResponse {
        HTTPResponse(status: status, reason: reason, contentType: "text/html; charset=utf-8", body: body)
    }

    var bytes: Data {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(payload.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Referrer-Policy: no-referrer\r\n"
            + "X-Content-Type-Options: nosniff\r\n"
            + "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'\r\n"
            + "Connection: close\r\n\r\n"
        return Data(head.utf8) + payload
    }
}

/// `application/x-www-form-urlencoded`, as a browser posts a form.
enum FormDecoding {
    static func decode(_ body: Data) -> [String: String] {
        var out: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = unescape(kv[0])
            out[key] = kv.count > 1 ? unescape(kv[1]) : ""
        }
        return out
    }

    private static func unescape(_ s: Substring) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
    }
}

/// The page the human sees: the Service, its Description, one input per Field —
/// a password input for a secret Field, plain text for a `--show` one.
enum LinkPage {
    static func inputName(_ index: Int) -> String { "f\(index)" }

    static func form(_ link: OneTimeLink, problem: String?) -> String {
        var inputs = ""
        for (i, field) in link.fields.enumerated() {
            let label = field.label.isEmpty ? "Secret" : field.label
            let type = field.masked ? "password" : "text"
            inputs += """
              <label for="\(inputName(i))">\(escape(label))</label>
              <input id="\(inputName(i))" name="\(inputName(i))" type="\(type)" required autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false"\(i == 0 ? " autofocus" : "")>

            """
        }
        var about = ""
        if let description = link.description, !description.isEmpty {
            about = "<p class=\"about\">\(escape(description))</p>\n"
        }
        let warning = problem.map { "<p class=\"problem\">\(escape($0))</p>\n" } ?? ""
        return page(title: "mytokens: \(link.service)", body: """
            <h1>\(escape(link.service))</h1>
            <p class="account">\(escape(link.service)) / \(escape(link.account))</p>
            \(about)\(warning)<form method="post" action="\(link.path)">
            \(inputs)  <button type="submit">Store</button>
            </form>
            <p class="note">This link works once and expires 10 minutes after it was made.</p>
            """)
    }

    static func sent(_ link: OneTimeLink) -> String {
        page(title: "mytokens: \(link.service)", body: """
            <h1>Sent</h1>
            <p>mytokens received the value for \(escape(link.service)) / \(escape(link.account)) and is storing it. This link no longer works.</p>
            """)
    }

    private static func page(title: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="robots" content="noindex">
        <title>\(escape(title))</title>
        <style>
        body { font: 16px -apple-system, system-ui, sans-serif; margin: 0 auto; max-width: 28rem; padding: 1.5rem 1rem; color: #1d1d1f; background: #fff; }
        @media (prefers-color-scheme: dark) { body { color: #f5f5f7; background: #1c1c1e; } input { background: #2c2c2e; color: #f5f5f7; border-color: #48484a; } }
        h1 { font-size: 1.4rem; margin: 0 0 .25rem; word-break: break-all; }
        .account, .note { color: #86868b; font-size: .875rem; }
        .about { margin: 1rem 0; }
        .problem { color: #d70015; }
        label { display: block; margin: 1rem 0 .25rem; font-weight: 600; }
        input { box-sizing: border-box; width: 100%; font-size: 1rem; padding: .6rem; border: 1px solid #d2d2d7; border-radius: 8px; }
        button { margin-top: 1.25rem; width: 100%; font-size: 1rem; padding: .7rem; border: 0; border-radius: 8px; background: #0071e3; color: #fff; }
        </style></head><body>
        \(body)
        </body></html>

        """
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }
}
