import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
@main struct SecureNetworkCheck {
  struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
  }
  static func check(_ value: Bool, _ reason: String) throws { if !value { throw Failure(reason) } }
  static func rejects(_ body: () throws -> Void, _ name: String) throws {
    do { try body() } catch { return }
    throw Failure("accepted \(name)")
  }
  // OpenSSL owns the host TLS socket. The request bytes, response framing, DAV methods and policy below are shipping Swift.
  static func roundTrip(_ req: URLRequest, _ dir: String, _ port: String, proxy: String?) throws
    -> DAVReply
  {
    let p = Process()
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    var args = [
      "s_client", "-quiet", "-connect", "localhost:\(port)", "-servername", "localhost", "-alpn",
      "http/1.1",
      "-CAfile", dir + "/ca.pem", "-verify_hostname", "localhost", "-verify_return_error",
    ]
    if let proxy { args += ["-proxy", "127.0.0.1:\(proxy)"] }
    p.arguments = args
    p.standardInput = input
    p.standardOutput = output
    p.standardError = error
    let wire = try HTTP11Message.request(req)
    try p.run()
    try input.fileHandleForWriting.write(contentsOf: wire)
    try input.fileHandleForWriting.close()
    var parser = HTTP11Reply(method: req.httpMethod ?? "GET", limit: 65536)
    while let bytes = try output.fileHandleForReading.read(upToCount: 257), !bytes.isEmpty {
      for b in bytes { try parser.receive(Data([b]), end: false) }
    }
    p.waitUntilExit()
    try check(
      p.terminationStatus == 0,
      "TLS fixture failed: "
        + String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    try parser.receive(Data(), end: true)
    return .init(
      status: parser.status, data: parser.body, etag: parser.fields["etag"],
      modified: parser.fields["last-modified"])
  }
  static func main() async {
    do { try await verify() } catch {
      print(error)
      exit(1)
    }
  }
  static func verify() async throws {
    let suite = "PiliCertificatePolicy." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    func accepts(_ method: String = "NSURLAuthenticationMethodServerTrust", trust: Bool = true, failures: Int = 0) -> Bool {
      ServerCertificatePolicy.acceptsChallenge(method: method, hasServerTrust: trust, failures: failures, defaults: defaults)
    }
    try check(!accepts(), "certificate validation defaults to enabled")
    defaults.set(true, forKey: ServerCertificatePolicy.key)
    try check(accepts() && !accepts("NSURLAuthenticationMethodHTTPBasic") && !accepts(trust: false)
      && !accepts(failures: 1), "explicit server-trust override only")
    defaults.set(false, forKey: ServerCertificatePolicy.key)
    try check(!accepts(), "disabling override restores default validation")
    let args = CommandLine.arguments
    let dir = args[1]
    let port = args[2]
    let proxy = args[3]
    func cert(_ name: String) throws -> PrivateCertificate {
      try PrivateCertificate(Data(contentsOf: URL(fileURLWithPath: dir + "/" + name + ".pem")))
    }
    let ca = try cert("ca")
    let leaf = try cert("localhost")
    let expired = try cert("expired")
    let wrong = try cert("wrong")
    try check(
      ca.authority && ca.valid() && !leaf.authority && leaf.valid() && !expired.valid()
        && !wrong.matches("localhost"), "certificate metadata")
    try check(
      leaf.matches("localhost") && leaf.matches("127.0.0.1") && leaf.matches("::1")
        && leaf.matches("one.fixture.test") && !leaf.matches("two.one.fixture.test")
        && !leaf.matches("fixture.test") && !leaf.matches("127.0.0.2"), "subjectAltName")
    try rejects({ _ = try PrivateCertificate(Data([48, 130, 255, 255])) }, "truncated DER")
    let u = URL(string: "https://localhost:\(port)/dav/fixture.json")!
    let a = PrivateServiceOrigin(.dav, u)!
    let b = PrivateServiceOrigin(.sponsor, u)!
    try check(
      a.key != b.key && a.matches("LOCALHOST.", Int(port)!) && !a.matches("localhost", 443)
        && !a.matches("other", Int(port)!), "origin scope")
    for s in [
      "https://api.bilibili.com", "https://passport.bilibili.com", "https://cdn.bilivideo.com",
      "https://sponsor.ajay.app", "https://www.bsbsb.top", "https://127.1", "http://localhost",
      "https://name:pw@localhost",
    ] {
      try check(PrivateServiceOrigin(.dav, URL(string: s)!) == nil, "protected origin")
    }
    try check(
      !HTTP11Message.requiresSystemSession(negotiate: false, contentType: nil)
        && HTTP11Message.requiresSystemSession(negotiate: true, contentType: nil)
        && HTTP11Message.requiresSystemSession(
          negotiate: false, contentType: "application/grpc+proto"),
      "gRPC routing")
    let origin = URL(string: "https://localhost")!
    try check(
      HTTP11Message.allowsRedirect(
        method: "GET", from: origin, to: URL(string: "https://LOCALHOST/a")!),
      "same-origin redirect")
    for (m, x) in [
      ("POST", "https://localhost/other"), ("GET", "http://localhost/a"),
      ("GET", "https://localhost:44/a"), ("GET", "https://other.example/a"),
      ("GET", "https://localhost/x/feed/dislike"), ("GET", "https://a:p@localhost/a"),
    ] {
      try check(
        !HTTP11Message.allowsRedirect(method: m, from: origin, to: URL(string: x)!),
        "redirect blocked")
    }
    var cookieReply = HTTP11Reply(limit: 256)
    try cookieReply.receive(
      Data(
        "HTTP/1.1 200 OK\r\nSet-Cookie: a=one; Expires=Thu, 31 Dec 2037 23:59:59 GMT; Path=/\r\nSet-Cookie: b=two; Path=/\r\nContent-Length: 0\r\n\r\n"
          .utf8), end: true)
    let names = cookieReply.setCookie.flatMap {
      HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": $0], for: u)
    }.map(\.name)
    try check(names == ["a", "b"], "separate QR cookie headers")
    let frames = [
      (
        "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4;test=yes\r\ntest\r\n0\r\nX-Trace: fixture\r\n\r\n",
        "test", 200
      ),
      ("HTTP/1.0 404 Not found\r\n\r\nnone", "none", 404),
      ("HTTP/1.1 204 No Content\r\n\r\n", "", 204),
    ]
    for (s, want, status) in frames {
      var p = HTTP11Reply(limit: 16)
      for b in s.utf8 { try p.receive(Data([b]), end: false) }
      try p.receive(Data(), end: true)
      try check(p.status == status && p.body == Data(want.utf8), "incremental parser")
    }
    for (h, b) in [
      ("Content-Length: 2\r\nContent-Length: 3", "xx"),
      ("Transfer-Encoding: chunked\r\nContent-Length: 2", ""), ("Content-Length: 9", ""),
      ("Content-Length: 2", "x"), ("Transfer-Encoding: chunked", "8\r\nXXXXXXXX?x"),
      ("Content-Length: 1", "xy"),
    ] {
      try rejects(
        {
          var p = HTTP11Reply(limit: 8)
          try p.receive(Data(("HTTP/1.1 200 OK\r\n" + h + "\r\n\r\n" + b).utf8), end: true)
        }, "invalid framing")
    }
    var rest = URLRequest(url: URL(string: "https://localhost:\(port)/api/item?q=a%2Fb")!)
    rest.setValue("fixture=synthetic", forHTTPHeaderField: "Cookie")
    rest.setValue("not-origin-data", forHTTPHeaderField: "Proxy-Authorization")
    let r = try roundTrip(rest, dir, port, proxy: nil)
    try check(r.status == 200 && r.data == Data("direct".utf8), "direct TLS HTTP/1.1")
    let dav = DAVStore(
      location: try .init(address: u.absoluteString, directory: "", tablet: false), user: "fixture",
      password: "test-only"
    ) { req in
      try roundTrip(req, dir, port, proxy: proxy)
    }
    try await dav.write { existing in
      try check(existing == Data("before".utf8), "DAV GET")
      return Data("after".utf8)
    }
    let again = try await dav.read()
    try check(again == Data("after".utf8), "DAV round trip")
    var attempts = 0
    do {
      _ = try await ConnectionRetry(count: 3, delayMillis: 0).perform(
        readOnly: !HTTP11Message.mutatingGET("/xlive/app-interface/v2/index/feedback")
      ) { _ -> Bool in
        attempts += 1
        throw URLError(.networkConnectionLost)
      }
    } catch is URLError {}
    try check(attempts == 1, "mutating GET must not replay")
    print(
      "Swift: certificate metadata and origin isolation, fragmented HTTP framing and limits, real direct TLS request, DAV conditional write and read through CONNECT, no write replay"
    )
  }
}
