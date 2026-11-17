import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

extension BiliAPI {
  func webResponse(_ request: URLRequest, identity: Identity, use: AccountUse = .role(.main)) async throws -> (Data, HTTPURLResponse) {
    let bound = try await AccountJar.shared.bindWeb(identity, use: use)
    return try await webResponse(request, bound: bound, use: use)
  }
  /// Every authenticated web response belongs to the session selected before the send.
  func webResponse(_ input: URLRequest, bound: WebSessionSnapshot, use: AccountUse = .role(.main)) async throws -> (Data, HTTPURLResponse) {
    try Task.checkCancellation()
    guard let url = input.url, WebCookieJar.webURL(url), try await AccountJar.shared.webMatches(bound, use: use) else {
      throw ServiceError("账号已切换")
    }
    var request = input
    request.httpShouldHandleCookies = false
    request.setValue(bound.header(for: url), forHTTPHeaderField: "Cookie")
    let result = try await session.response(for: request)
    try Task.checkCancellation()
    guard try await AccountJar.shared.webMatches(bound, use: use) else { throw ServiceError("账号已切换") }
    let invalid = bound.owner != nil && InvalidWebSession.confirmed(result.data, status: result.http.statusCode, url: result.http.url ?? url)
    if invalid, try await AccountJar.shared.revokeInvalidMain(bound, cookies: result.cookies, from: result.http.url ?? url), let owner = bound.owner {
      await InvalidWebSession.announce(owner)
      throw ServiceError("账号未登录，请重新登录", code: -101)
    }
    var confirmed: String?
    if url.host == "api.bilibili.com", url.path == "/x/web-interface/nav",
      let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any], json["code"] as? Int == 0,
      let person = json["data"] as? [String: Any], person["isLogin"] as? Bool == true, let uid = person["mid"] as? NSNumber,
      uid.stringValue == bound.owner { confirmed = uid.stringValue }
    guard try await AccountJar.shared.mergeResponseCookies(result.cookies, from: result.http.url ?? url, bound: bound, use: use, verifiedOwner: confirmed) != nil else {
      throw ServiceError("账号已切换")
    }
    if invalid { throw ServiceError("账号未登录，请重新登录", code: -101) }
    return (result.data, result.http)
  }
}
