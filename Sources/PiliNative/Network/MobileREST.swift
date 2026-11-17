import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// The pinned AccountManager signs every app REST request; app credentials are not web cookies.
enum MobileREST {
  struct Session: Equatable, Sendable {
    let owner: String?, token: String?, device: String, routing: String
  }
  static func require(_ bound: Session, matches current: Session) throws {
    guard bound == current else { throw ServiceError("账号授权已变更，请重试") }
  }
  static func request(
    path: String, fields: [String: String], session: Session,
    timestamp: Int64 = Int64(Date().timeIntervalSince1970)
  ) throws -> URLRequest {
    guard path.hasPrefix("/"), !path.contains("?"), !path.contains("#") else { throw URLError(.badURL) }
    var fields = fields
    // Explicit fields cannot replace the account selected for this API's role.
    fields.removeValue(forKey: "access_key")
    if let token = session.token, !token.isEmpty { fields["access_key"] = token }
    var url = URLComponents()
    url.scheme = "https"; url.host = "app.bilibili.com"; url.path = path
    url.percentEncodedQuery = MobileClientSigning.formEncoded(MobileClientSigning.signed(fields, timestamp: timestamp))
    guard let address = url.url else { throw URLError(.badURL) }
    return try decorated(URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18), session: session)
  }
  static func decorated(_ request: URLRequest, session: Session) throws -> URLRequest {
    guard let url = request.url, url.scheme == "https", url.host == "app.bilibili.com",
      url.user == nil, url.password == nil, url.port == nil || url.port == 443,
      MobileDeviceID.valid(session.device)
    else { throw URLError(.unsupportedURL) }
    var result = request
    result.httpShouldHandleCookies = false
    result.setValue(nil, forHTTPHeaderField: "Cookie")
    result.setValue(nil, forHTTPHeaderField: "Authorization")
    result.setValue(session.device, forHTTPHeaderField: "buvid")
    result.setValue(MobileClientSigning.userAgent, forHTTPHeaderField: "User-Agent")
    result.setValue("android_hd", forHTTPHeaderField: "app-key")
    result.setValue("prod", forHTTPHeaderField: "env")
    result.setValue(session.owner, forHTTPHeaderField: "x-bili-mid")
    if result.value(forHTTPHeaderField: "Referer") == nil {
      result.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    }
    if url.path == "/x/v2/feed/index" {
      let fingerprint = String(repeating: "1", count: 64)
      result.setValue(fingerprint, forHTTPHeaderField: "fp_local")
      result.setValue(fingerprint, forHTTPHeaderField: "fp_remote")
      result.setValue("11111111", forHTTPHeaderField: "session_id")
    }
    return result
  }
  static func transfer(
    _ request: URLRequest, session: Session,
    current: () async throws -> Session,
    via: (URLRequest) async throws -> (Data, URLResponse)
  ) async throws -> (Data, URLResponse) {
    try Task.checkCancellation()
    try require(session, matches: await current())
    let result = try await via(decorated(request, session: session))
    try Task.checkCancellation()
    try require(session, matches: await current())
    return result
  }
}
