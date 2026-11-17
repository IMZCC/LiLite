import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum AccountExitRequest {
  static func make(header: String, csrf: String) throws -> URLRequest {
    guard !header.isEmpty, header.utf8.count <= 64 * 1024,
      header.rangeOfCharacter(from: .controlCharacters) == nil, !csrf.isEmpty,
      let body = csrf.addingPercentEncoding(
        withAllowedCharacters: CharacterSet(
          charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))
    else { throw ServiceError("登录信息无效") }
    var r = URLRequest(
      url: URL(string: "https://passport.bilibili.com/login/exit/v2")!, timeoutInterval: 15)
    r.httpMethod = "POST"
    r.httpShouldHandleCookies = false
    r.httpBody = Data(("biliCSRF=" + body).utf8)
    r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    r.setValue(header, forHTTPHeaderField: "Cookie")
    r.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    return r
  }
  static func check(_ data: Data, status: Int) throws {
    struct Response: Decodable {
      let code: Int
      let message: String?
    }
    guard status == 200, data.count < 128 * 1024 else { throw ServiceError("服务端未确认退出") }
    let r = try JSONDecoder().decode(Response.self, from: data)
    guard r.code == 0 else { throw ServiceError(r.message ?? "服务端未确认退出") }
  }
}
