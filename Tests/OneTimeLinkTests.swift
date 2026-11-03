import XCTest

// The one-time link's rules with no sockets: the token, single use, expiry, and the
// page it serves. The clock is passed in, so expiry needs no waiting.
final class OneTimeLinkTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeLink(fields: [Field] = [Field(label: "Token", masked: true)],
                          description: String? = "CI deploy") -> OneTimeLink {
        OneTimeLink(service: "svc", account: "default", description: description, fields: fields,
                    expires: t0.addingTimeInterval(OneTimeLink.lifetime))
    }

    private func get(_ path: String) -> HTTPRequest { HTTPRequest(method: "GET", path: path, body: Data()) }
    private func post(_ path: String, _ body: String) -> HTTPRequest {
        HTTPRequest(method: "POST", path: path, body: Data(body.utf8))
    }

    func testTokenIsFresh128BitHex() {
        let a = OneTimeLink.freshToken(), b = OneTimeLink.freshToken()
        XCTAssertEqual(a.count, 32)
        XCTAssertTrue(a.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertNotEqual(a, b)
        let link = makeLink()
        XCTAssertEqual(link.path, "/" + link.token)
        XCTAssertEqual(OneTimeLink.lifetime, 600)
    }

    func testTheRightTokenSubmitsOnce() {
        var link = makeLink()
        let first = link.handle(post(link.path, "f0=s3cr%26t+x"), now: t0)
        XCTAssertEqual(first.response.status, 200)
        XCTAssertEqual(first.submitted, ["Token": "s3cr&t x"])

        let second = link.handle(post(link.path, "f0=other"), now: t0)
        XCTAssertEqual(second.response.status, 410)
        XCTAssertNil(second.submitted)
        XCTAssertEqual(link.handle(get(link.path), now: t0).response.status, 410)   // the page is gone too
    }

    func testAWrongTokenIsRefusedAndConsumesNothing() {
        var link = makeLink()
        var wrong = link.token
        wrong.removeLast()
        wrong += link.token.hasSuffix("0") ? "1" : "0"
        for path in ["/" + wrong, "/", "/favicon.ico", link.path + "x", "/" + link.token.prefix(31)] {
            let r = link.handle(post(path, "f0=evil"), now: t0)
            XCTAssertEqual(r.response.status, 404, path)
            XCTAssertNil(r.submitted, path)
            XCTAssertFalse(r.response.body.contains("svc"), path)       // tells a stranger nothing
        }
        XCTAssertEqual(link.handle(post(link.path, "f0=good"), now: t0).submitted, ["Token": "good"])
    }

    func testAfterTenMinutesItIsRefused() {
        var link = makeLink()
        XCTAssertEqual(link.handle(get(link.path), now: t0.addingTimeInterval(599)).response.status, 200)
        let late = link.handle(post(link.path, "f0=late"), now: t0.addingTimeInterval(600))
        XCTAssertEqual(late.response.status, 410)
        XCTAssertNil(late.submitted)
    }

    func testAnEmptyFieldIsAskedAgainWithoutUsingTheLink() {
        var link = makeLink(fields: [Field(label: "Access Key ID", masked: false), Field(label: "Secret", masked: true)])
        let partial = link.handle(post(link.path, "f0=AKIA&f1="), now: t0)
        XCTAssertEqual(partial.response.status, 400)
        XCTAssertNil(partial.submitted)
        XCTAssertFalse(link.used)
        XCTAssertEqual(link.handle(post(link.path, "f0=AKIA&f1=s"), now: t0).submitted,
                       ["Access Key ID": "AKIA", "Secret": "s"])
    }

    func testOtherMethodsAreRefused() {
        var link = makeLink()
        let r = link.handle(HTTPRequest(method: "PUT", path: link.path, body: Data("f0=x".utf8)), now: t0)
        XCTAssertEqual(r.response.status, 405)
        XCTAssertNil(r.submitted)
        XCTAssertFalse(link.used)
    }

    func testThePageShowsServiceDescriptionAndFields() {
        var link = makeLink(fields: [Field(label: "Access Key ID", masked: false), Field(label: "Secret <Key>", masked: true)],
                            description: "deploy & <b>sync</b>")
        let page = link.handle(get(link.path + "?x=1"), now: t0).response
        XCTAssertEqual(page.status, 200)
        XCTAssertEqual(page.contentType, "text/html; charset=utf-8")
        XCTAssertTrue(page.body.contains("<h1>svc</h1>"))
        XCTAssertTrue(page.body.contains("deploy &amp; &lt;b&gt;sync&lt;/b&gt;"))         // escaped
        XCTAssertTrue(page.body.contains(#"<label for="f0">Access Key ID</label>"#))
        XCTAssertTrue(page.body.contains(#"<label for="f1">Secret &lt;Key&gt;</label>"#))
        XCTAssertTrue(page.body.contains(#"name="f0" type="text""#))                    // --show
        XCTAssertTrue(page.body.contains(#"name="f1" type="password""#))                // secret
        XCTAssertTrue(page.body.contains(#"action="\#(link.path)""#))
        let head = String(decoding: page.bytes, as: UTF8.self)
        XCTAssertTrue(head.contains("Cache-Control: no-store\r\n"))
        XCTAssertTrue(head.contains("Referrer-Policy: no-referrer\r\n"))
    }

    func testTheBareSecretIsLabelledSecretOnThePage() {
        var link = makeLink(fields: [Field(label: "", masked: true)], description: nil)
        XCTAssertTrue(link.handle(get(link.path), now: t0).response.body.contains(#"<label for="f0">Secret</label>"#))
        XCTAssertEqual(link.handle(post(link.path, "f0=v"), now: t0).submitted, ["": "v"])
    }

    func testRequestParsing() {
        let raw = "POST /abc HTTP/1.1\r\nHost: x\r\nContent-Length: 7\r\n\r\nf0=a%20"
        guard case .complete(let request) = HTTPRequest.parse(Data(raw.utf8)) else { return XCTFail("not parsed") }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/abc")
        XCTAssertEqual(FormDecoding.decode(request.body), ["f0": "a "])

        guard case .incomplete = HTTPRequest.parse(Data("POST /abc HTTP/1.1\r\nContent-Length: 9\r\n\r\nf0=".utf8)) else {
            return XCTFail("a short body is incomplete")
        }
        guard case .incomplete = HTTPRequest.parse(Data("GET /abc HTTP/1.1\r\n".utf8)) else {
            return XCTFail("a head without its blank line is incomplete")
        }
        guard case .invalid = HTTPRequest.parse(Data("hello\r\n\r\n".utf8)) else { return XCTFail("not HTTP") }
        guard case .invalid = HTTPRequest.parse(Data(count: HTTPRequest.maxBytes + 1)) else { return XCTFail("too big") }
    }
}

// The real listener on loopback: the link is served, used once, and closed; an
// unused link expires. (Live, it binds to the tailnet address instead.)
final class LinkServerTests: XCTestCase {
    private func linkInput(lifetime: TimeInterval, announced: @escaping (String) -> Void) -> LinkSecretInput {
        LinkSecretInput(endpoint: { LinkEndpoint(bindAddress: "127.0.0.1", tls: nil, plainHTTPReason: "test") },
                        announce: announced, lifetime: lifetime)
    }

    /// Plain HTTP over a socket, so the test sees exactly what a browser would.
    private func send(_ url: URL, method: String, body: String = "") -> (status: Int, body: String)? {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = method
        if method == "POST" {
            request.httpBody = Data(body.utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let done = expectation(description: "\(method) \(url)")
        var result: (Int, String)?
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse { result = (http.statusCode, String(decoding: data ?? Data(), as: UTF8.self)) }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return result
    }

    private func announcedURL(_ text: String) -> URL? {
        text.split(whereSeparator: \.isWhitespace).first { $0.hasPrefix("http") }.flatMap { URL(string: String($0)) }
    }

    func testTheLinkIsServedUsedOnceAndClosed() {
        var announced = ""
        let ready = expectation(description: "link announced")
        let input = linkInput(lifetime: 30) { announced = $0; ready.fulfill() }

        var result: PromptResult?
        let finished = expectation(description: "prompt returned")
        DispatchQueue.global().async {
            result = input.promptForSecret(service: "svc", account: "default", description: "CI",
                                           fields: [Field(label: "Token", masked: true)])
            finished.fulfill()
        }
        wait(for: [ready], timeout: 10)
        XCTAssertTrue(announced.contains("plain HTTP"), announced)
        guard let url = announcedURL(announced) else { return XCTFail("no link in: \(announced)") }
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.path.count, 33)                                    // "/" + 32 hex digits

        var wrong = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        wrong.path = "/" + String(repeating: "0", count: 32)
        XCTAssertEqual(send(wrong.url!, method: "POST", body: "f0=evil")?.status, 404)

        let page = send(url, method: "GET")
        XCTAssertEqual(page?.status, 200)
        XCTAssertTrue(page?.body.contains(#"type="password""#) ?? false)

        XCTAssertEqual(send(url, method: "POST", body: "f0=tok%2Bvalue")?.status, 200)
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(result, .entered(["Token": "tok+value"]))

        // Second use: the listener is closed, so nothing answers at all.
        XCTAssertNil(send(url, method: "POST", body: "f0=again"))
    }

    func testAnUnusedLinkExpiresAndCloses() {
        var announced = ""
        let input = linkInput(lifetime: 1) { announced = $0 }
        let started = Date()
        let result = input.promptForSecret(service: "svc", account: "default", description: nil,
                                           fields: [Field(label: "", masked: true)])
        XCTAssertEqual(result, .expired)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        guard let url = announcedURL(announced) else { return XCTFail("no link in: \(announced)") }
        XCTAssertNil(send(url, method: "POST", body: "f0=late"))
    }

    func testNoTailnetIsUnavailable() {
        let input = LinkSecretInput(endpoint: { nil }, announce: { _ in XCTFail("nothing to announce") })
        XCTAssertEqual(input.promptForSecret(service: "svc", account: "default", description: nil,
                                             fields: [Field(label: "", masked: true)]), .unavailable)
    }
}

// HTTPS: a PEM certificate and key (as `tailscale cert` writes them) become an
// in-memory identity, and the link is served over TLS with it.
final class LinkTLSTests: XCTestCase {
    private final class TrustAnything: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard let trust = challenge.protectionSpace.serverTrust else { return completionHandler(.performDefaultHandling, nil) }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    func testAPEMCertificateServesTheLinkOverHTTPS() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mytokens-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cert = dir.appendingPathComponent("cert.pem").path, key = dir.appendingPathComponent("key.pem").path
        let openssl = Process()
        openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        // A named curve, as a real (Let's Encrypt) certificate has: LibreSSL writes explicit
        // parameters by default, which the Security framework cannot read.
        openssl.arguments = ["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
                             "-pkeyopt", "ec_param_enc:named_curve", "-nodes",
                             "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=localhost"]
        openssl.standardOutput = FileHandle.nullDevice
        openssl.standardError = FileHandle.nullDevice
        try openssl.run()
        openssl.waitUntilExit()
        XCTAssertEqual(openssl.terminationStatus, 0)

        let identity: SecIdentity
        switch TLSIdentity.load(certPEM: cert, keyPEM: key) {
        case .success(let id): identity = id
        case .failure(let refusal): return XCTFail(refusal.message)
        }

        var announced = ""
        let ready = expectation(description: "announced")
        let input = LinkSecretInput(
            endpoint: { LinkEndpoint(bindAddress: "127.0.0.1", tls: (identity, "127.0.0.1"), plainHTTPReason: nil) },
            announce: { announced = $0; ready.fulfill() }, lifetime: 30)
        var result: PromptResult?
        let finished = expectation(description: "returned")
        DispatchQueue.global().async {
            result = input.promptForSecret(service: "svc", account: "default", description: nil,
                                           fields: [Field(label: "Token", masked: true)])
            finished.fulfill()
        }
        wait(for: [ready], timeout: 10)
        XCTAssertFalse(announced.contains("plain HTTP"), announced)
        guard let url = announced.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("https://") })
            .flatMap({ URL(string: String($0)) }) else { return XCTFail("no https link in: \(announced)") }

        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.httpBody = Data("f0=over-tls".utf8)
        let posted = expectation(description: "posted")
        var status: Int?
        URLSession(configuration: .ephemeral, delegate: TrustAnything(), delegateQueue: nil)
            .dataTask(with: request) { _, response, _ in
                status = (response as? HTTPURLResponse)?.statusCode
                posted.fulfill()
            }.resume()
        wait(for: [posted, finished], timeout: 10)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(result, .entered(["Token": "over-tls"]))
    }
}
