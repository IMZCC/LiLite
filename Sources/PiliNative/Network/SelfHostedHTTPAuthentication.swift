import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

/// A dedicated DAV session may answer its configured server's Basic/Digest challenge only.
struct SelfHostedHTTPAuthentication {
  let origin: URL, user: String, password: String
  static func handles(_ method: String) -> Bool {
    [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest].contains(method)
  }
  func credential(for challenge: URLAuthenticationChallenge) -> URLCredential? {
    let space = challenge.protectionSpace
    let stale = (challenge.failureResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate")
      .flatMap { $0.range(of: #"(?:^|,)\s*stale\s*=\s*\"?true\"?(?:,|$)"#, options: [.regularExpression, .caseInsensitive]) } != nil
    guard Self.handles(space.authenticationMethod), challenge.previousFailureCount == 0
        || (challenge.previousFailureCount == 1 && space.authenticationMethod == NSURLAuthenticationMethodHTTPDigest && stale),
      !user.isEmpty, !user.contains(":"), user.rangeOfCharacter(from: .controlCharacters) == nil,
      SelfHostedServiceURL.matches(origin, host: space.host, port: space.port, scheme: space.protocol)
    else { return nil }
    return URLCredential(user: user, password: password, persistence: .none)
  }
  /// Also handles servers/transports which return a Digest 401 without a URLSession challenge.
  /// Only this exact origin can cause a retry; an expired Digest nonce may be renewed once.
  func retry(_ request: URLRequest, challenge: String) throws -> URLRequest? {
    guard let url = request.url, SelfHostedServiceURL.sameOrigin(origin, url), !user.isEmpty,
      !user.contains(":"), user.rangeOfCharacter(from: .controlCharacters) == nil,
      challenge.utf8.count <= 8192, challenge.lowercased().hasPrefix("digest "),
      challenge.rangeOfCharacter(from: .controlCharacters) == nil, request.httpBodyStream == nil else { return nil }
    let pattern = #"([A-Za-z][A-Za-z0-9_-]*)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^,\s]+))"#
    let regex = try NSRegularExpression(pattern: pattern)
    let source = challenge as NSString
    var fields: [String: String] = [:]
    for match in regex.matches(in: challenge, range: NSRange(location: 7, length: source.length - 7)) {
      let key = source.substring(with: match.range(at: 1)).lowercased()
      guard fields[key] == nil else { return nil }
      let range = match.range(at: 2).location == NSNotFound ? match.range(at: 3) : match.range(at: 2)
      let quoted = source.substring(with: range)
      fields[key] = quoted.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
    }
    guard let realm = fields["realm"], let nonce = fields["nonce"], !nonce.isEmpty else { return nil }
    if request.value(forHTTPHeaderField: "Authorization")?.lowercased().hasPrefix("digest ") == true,
      fields["stale"]?.lowercased() != "true" { return nil }
    let algorithm = fields["algorithm"]?.uppercased() ?? "MD5"
    guard ["MD5", "MD5-SESS", "SHA-256", "SHA-256-SESS"].contains(algorithm) else { return nil }
    func hash(_ bytes: Data) -> String {
      let result = algorithm.hasPrefix("SHA-256") ? Array(SHA256.hash(data: bytes)) : Array(Insecure.MD5.hash(data: bytes))
      return result.map { String(format: "%02x", $0) }.joined()
    }
    func digest(_ text: String) -> String { hash(Data(text.utf8)) }
    let qops = fields["qop"].map { $0.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    let qop: String?
    if let qops { if qops.contains("auth") { qop = "auth" } else if qops.contains("auth-int") { qop = "auth-int" } else { return nil } }
    else { qop = nil }
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    let uri = (parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath) + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
    let cnonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), count = "00000001"
    var a1 = digest(user + ":" + realm + ":" + password)
    if algorithm.hasSuffix("-SESS") { a1 = digest(a1 + ":" + nonce + ":" + cnonce) }
    let a2 = digest((request.httpMethod ?? "GET") + ":" + uri + (qop == "auth-int" ? ":" + hash(request.httpBody ?? Data()) : ""))
    let response = digest(a1 + ":" + nonce + ":" + (qop.map { count + ":" + cnonce + ":" + $0 + ":" } ?? "") + a2)
    func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    var auth = ["username=" + quoted(user), "realm=" + quoted(realm), "nonce=" + quoted(nonce), "uri=" + quoted(uri), "response=" + quoted(response), "algorithm=" + algorithm]
    if let opaque = fields["opaque"] { auth.append("opaque=" + quoted(opaque)) }
    if let qop { auth += ["qop=" + qop, "nc=" + count, "cnonce=" + quoted(cnonce)] }
    else if algorithm.hasSuffix("-SESS") { auth.append("cnonce=" + quoted(cnonce)) }
    var next = request; next.setValue("Digest " + auth.joined(separator: ", "), forHTTPHeaderField: "Authorization")
    return next
  }
}
