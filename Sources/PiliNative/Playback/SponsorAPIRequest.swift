import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum SponsorAPIRequest {
  static let defaultServer = "https://www.bsbsb.top"
  static func make(base: URL, path: String, method: String = "GET", query: [String: String] = [:],
    body: [String: Any]? = nil) throws -> URLRequest {
    guard SelfHostedServiceURL.parse(base.absoluteString) != nil else { throw ServiceError("空降助手地址无效") }
    var parts = URLComponents(url: base.appendingPathComponent("api").appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    parts.queryItems = query.isEmpty ? nil : query.sorted { $0.key < $1.key }.map(URLQueryItem.init)
    guard let url = parts.url, SelfHostedServiceURL.sameOrigin(base, url) else { throw ServiceError("空降助手地址无效") }
    var request = URLRequest(url: url, timeoutInterval: 12)
    request.httpMethod = method; request.httpShouldHandleCookies = false
    request.setValue("PiliNative", forHTTPHeaderField: "Origin")
    request.setValue("2.2.0.2", forHTTPHeaderField: "X-Ext-Version")
    if let body {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return request
  }
}
