import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@main enum WebAccountCookiesCheck {
  static func main() {
    func cookie(
      _ name: String, _ value: String, _ domain: String, _ path: String = "/",
      _ expires: Date? = nil
    ) -> HTTPCookie {
      var fields: [HTTPCookiePropertyKey: Any] = [
        .name: name, .value: value, .domain: domain, .path: path, .secure: "TRUE",
      ]
      fields[.expires] = expires
      return HTTPCookie(properties: fields)!
    }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let grant = WebLoginIdentity.values(
      [
        cookie("SESSDATA", "session", ".bilibili.com"), cookie("bili_jct", "csrf", ".bilibili.com"),
        cookie("DedeUserID", "42", ".bilibili.com"),
        cookie("SESSDATA", "unrelated", ".other.example"),
        cookie("SESSDATA", "hostOnly", "passport.bilibili.com"),
        cookie("bili_jct", "scoped", ".bilibili.com", "/passport"),
        cookie("sid", "expired", ".bilibili.com", "/", now.addingTimeInterval(-100)),
        cookie("anything", "skip", ".bilibili.com"),
      ], now: now)
    precondition(grant == ["SESSDATA": "session", "bili_jct": "csrf", "DedeUserID": "42"])
    precondition(!WebLoginIdentity.valid("a;b") && !WebLoginIdentity.valid("a\r\nb"))
    print("Login grant: only expected live root cookies scoped to Bilibili passed")
  }
}
