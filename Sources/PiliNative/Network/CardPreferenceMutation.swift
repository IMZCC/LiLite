import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum CardPreferenceMutation {
  case feed(kind: String, id: Int64, group: String, reason: Int64, undo: Bool)
  case archive(id: Int64, undo: Bool)
  var role: AccountRole {
    switch self {
    case .feed: return .recommend
    case .archive: return .main
    }
  }
  func sendOnce(
    expected: String, actor: String?, token: String?, timestamp: Int64 = Int64(Date().timeIntervalSince1970),
    via: (URLRequest) async throws -> (Data, URLResponse)
  ) async throws {
    guard !expected.isEmpty, actor == expected else { throw ServiceError("账号已切换") }
    guard let token, !token.isEmpty else { throw ServiceError("请先为\(role.title)完成移动端授权") }
    var form = ["access_key": token]
    let path: String
    let post: Bool
    switch self {
    case .feed(let kind, let id, let group, let reason, let undo):
      guard !kind.isEmpty, id > 0, ["feedback", "dislike"].contains(group) else {
        throw ServiceError("推荐卡片已变更")
      }
      path = undo ? "/x/feed/dislike/cancel" : "/x/feed/dislike"
      post = false
      form["goto"] = kind
      form["id"] = String(id)
      form[group == "feedback" ? "feedback_id" : "reason_id"] = String(reason)
      form["build"] = "1"
      form["mobi_app"] = "android"
    case .archive(let id, let undo):
      guard id > 0 else { throw ServiceError("没有视频编号") }
      path = "/x/v2/view/dislike"
      post = true
      form["aid"] = String(id)
      form["dislike"] = undo ? "1" : "0"
    }
    let body = MobileClientSigning.formEncoded(MobileClientSigning.signed(form, timestamp: timestamp))
    var c = URLComponents()
    c.scheme = "https"
    c.host = "app.bilibili.com"
    c.path = path
    if !post { c.percentEncodedQuery = body }
    guard let u = c.url else { throw URLError(.badURL) }
    var request = URLRequest(
      url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
    request.httpShouldHandleCookies = false
    request.setValue(MobileClientSigning.userAgent, forHTTPHeaderField: "User-Agent")
    if post {
      request.httpMethod = "POST"
      request.httpBody = Data(body.utf8)
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    }
    // Both HTTP methods mutate state. A lost acknowledgement cannot be retried safely.
    let (bytes, http) = try await via(request)
    guard (http as? HTTPURLResponse)?.statusCode == 200 else { throw ServiceError("未能提交反馈") }
    struct Ack: Decodable { let code: Int, message: String? }
    let ack = try JSONDecoder().decode(Ack.self, from: bytes)
    guard ack.code == 0 else { throw ServiceError(ack.message ?? "未能提交反馈") }
  }
  static func restore<T: Identifiable>(_ row: T, at index: Int, to rows: inout [T]) {
    guard !rows.contains(where: { $0.id == row.id }) else { return }
    rows.insert(row, at: min(max(0, index), rows.count))
  }
}
