import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum WebLoginIdentity {
  static let keys = Set(["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"])
  static func values(_ cookies: [HTTPCookie], now: Date = .now) -> [String: String] {
    var result = [String: String]()
    for c in cookies where keys.contains(c.name) {
      // The app uses these cookies on API subdomains. Never broaden a host-only passport cookie.
      guard c.domain.lowercased() == ".bilibili.com", c.path == "/",
        c.expiresDate.map({ $0 > now }) ?? true, valid(c.value)
      else { continue }
      result[c.name] = c.value
    }
    return result
  }
  static func valid(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 8192
      && value.utf8.allSatisfy { $0 >= 33 && $0 < 127 && $0 != 59 }
  }
}
