import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct WebCookieValue: Codable, Equatable, Sendable {
  let name: String, value: String, domain: String, path: String
  let hostOnly: Bool, secure: Bool
  let expires: Date?
  var key: String { domain + "\n" + path + "\n" + name }
  var global: Bool { domain == "bilibili.com" && path == "/" && !hostOnly }
  func applies(to url: URL, now: Date) -> Bool {
    guard let host = url.host?.lowercased(), expires.map({ $0 > now }) ?? true,
      !secure || url.scheme == "https",
      host == domain || (!hostOnly && host.hasSuffix("." + domain)) else { return false }
    let target = url.path.isEmpty ? "/" : url.path
    return target == path || (target.hasPrefix(path) && (path.hasSuffix("/") || target.dropFirst(path.count).first == "/"))
  }
  var cookie: HTTPCookie? {
    var fields: [HTTPCookiePropertyKey: Any] = [
      .name: name, .value: value, .domain: hostOnly ? domain : "." + domain, .path: path,
    ]
    if secure { fields[.secure] = "TRUE" }
    if let expires { fields[.expires] = expires }
    return HTTPCookie(properties: fields)
  }
}

enum WebCookieJar {
  static func newBuvid3() -> String { UUID().uuidString.uppercased() + String(format: "%05d", Int.random(in: 0..<100_000)) + "infoc" }
  static let core: Set<String> = ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5"]
  static let guestNames: Set<String> = ["buvid3", "buvid4", "b_nut", "b_lsid", "_uuid", "sid", "bili_ticket", "bili_ticket_expires", "buvid_fp", "buvid_fp_plain"]
  static func webURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
      url.port == nil || url.port == 443, let host = url.host?.lowercased(), host != "app.bilibili.com"
    else { return false }
    return host == "bilibili.com" || host.hasSuffix(".bilibili.com")
  }
  static func all(_ legacy: [String: String], _ stored: [WebCookieValue]) -> [WebCookieValue] {
    let represented = Set(stored.filter { $0.domain == "bilibili.com" && $0.path == "/" }.map(\.name))
    return stored + legacy.compactMap { name, value in
      represented.contains(name) ? nil : WebCookieValue(name: name, value: value, domain: "bilibili.com", path: "/", hostOnly: false, secure: true, expires: nil)
    }
  }
  static func values(_ legacy: [String: String], _ stored: [WebCookieValue], for url: URL, now: Date = Date()) -> [String: String] {
    guard webURL(url) else { return [:] }
    let applicable = all(legacy, stored).filter { $0.applies(to: url, now: now) }.sorted {
      if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
      if $0.domain.count != $1.domain.count { return $0.domain.count > $1.domain.count }
      return $0.hostOnly && !$1.hostOnly
    }
    var result: [String: String] = [:]
    for cookie in applicable where result[cookie.name] == nil { result[cookie.name] = cookie.value }
    return result
  }
  static func root(_ legacy: [String: String], _ stored: [WebCookieValue], now: Date = Date()) -> [String: String] {
    var result = legacy
    for row in stored where row.domain == "bilibili.com" && row.path == "/" {
      result[row.name] = !row.global || row.expires.map { $0 <= now } == true ? nil : row.value
    }
    return result
  }
  static func header(_ values: [String: String]) -> String {
    values.keys.sorted().map { $0 + "=" + values[$0]! }.joined(separator: "; ")
  }
  struct Update {
    let legacy: [String: String], stored: [WebCookieValue], verifyIdentity: Bool
  }
  static func update(legacy: [String: String], stored: [WebCookieValue], cookies: [HTTPCookie], from url: URL,
    owner: String?, now: Date = Date()) throws -> Update
  {
    guard webURL(url) else { return .init(legacy: legacy, stored: stored, verifyIdentity: false) }
    let allowed = Set("!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    var values = legacy, records = stored
    var changedCore = false
    for cookie in cookies.prefix(128) {
      let origin = ResponseCookieOrigin.source(cookie, fallback: url)
      guard webURL(origin), let host = origin.host?.lowercased() else { continue }
      let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
      guard domain == "bilibili.com" || domain.hasSuffix(".bilibili.com"),
        host == domain || host.hasSuffix("." + domain), !cookie.name.isEmpty, cookie.name.utf8.count <= 128,
        cookie.name.utf8.allSatisfy(allowed.contains), cookie.value.utf8.count <= 16_384,
        cookie.value.utf8.allSatisfy({ (33...126).contains($0) && ![34, 59, 92].contains($0) }),
        cookie.path.hasPrefix("/"), cookie.path.utf8.count <= 2048,
        !cookie.path.contains("\\"), cookie.path.rangeOfCharacter(from: .controlCharacters) == nil
      else { continue }
      let hostOnly = domain == host && !cookie.domain.hasPrefix(".")
      // Login credentials are a Bilibili root-domain session. Narrow-scope cookies stay scoped,
      // and cannot shadow the account's authenticated identity on an unrelated path or host.
      if core.contains(cookie.name), !(domain == "bilibili.com" && cookie.path == "/" && !hostOnly) { continue }
      if owner == nil, !guestNames.contains(cookie.name) { continue }
      var expiry = cookie.expiresDate
      if let age = cookie.properties?[.maximumAge], let seconds = Double(String(describing: age)), seconds.isFinite {
        expiry = now.addingTimeInterval(seconds)
      }
      guard expiry?.timeIntervalSince1970.isFinite ?? true else { continue }
      let deleted = expiry.map { $0 <= now } == true || cookie.value.isEmpty
      if cookie.name == "DedeUserID", !deleted, let owner, cookie.value != owner {
        throw ServiceError("响应的账号信息不匹配")
      }
      let record = WebCookieValue(name: cookie.name, value: cookie.value, domain: domain, path: cookie.path,
        hostOnly: hostOnly, secure: cookie.isSecure, expires: expiry)
      records.removeAll { $0.key == record.key }
      if !deleted { records.append(record) }
      if record.global {
        if core.contains(record.name), values[record.name] != (deleted ? nil : record.value) { changedCore = true }
        values[record.name] = deleted ? nil : record.value
      } else if record.domain == "bilibili.com", record.path == "/" {
        values[record.name] = nil
      }
    }
    for row in records where row.global && row.expires.map({ $0 <= now }) == true && values[row.name] == row.value { values[row.name] = nil }
    records.removeAll { $0.expires.map { $0 <= now } == true }
    guard records.count <= 256, values.count <= 128 else { throw ServiceError("响应的 Cookie 过多") }
    return .init(legacy: values, stored: records, verifyIdentity: owner != nil && changedCore && values["SESSDATA"]?.isEmpty == false)
  }
}

struct WebSessionSnapshot: Equatable, Sendable {
  let owner: String?, legacyCookies: [String: String], storedCookies: [WebCookieValue], token: String?, device: String
  let active: String?, routes: AccountRoutes
  var cookies: [String: String] { WebCookieJar.root(legacyCookies, storedCookies) }
  var header: String { WebCookieJar.header(cookies) }
  var siteDeviceID: String? { cookies["buvid3"] }
  func header(for url: URL) -> String { WebCookieJar.header(WebCookieJar.values(legacyCookies, storedCookies, for: url)) }
  func csrf(for url: URL) -> String? { WebCookieJar.values(legacyCookies, storedCookies, for: url)["bili_jct"] }
  func sameIdentity(as other: Self) -> Bool {
    let names = WebCookieJar.core.union(["buvid3", "buvid4"])
    return owner == other.owner && token == other.token && device == other.device && active == other.active && routes == other.routes
      && names.allSatisfy { legacyCookies[$0] == other.legacyCookies[$0] }
  }
}

struct WebLoginInspection {
  let cookies: [String: String], name: String, responseCookies: [HTTPCookie]
}

enum InvalidWebSession {
  static func confirmed(_ bytes: Data, status: Int, url: URL) -> Bool {
    guard status == 200, url.host == "api.bilibili.com", url.path == "/x/web-interface/nav", WebCookieJar.webURL(url),
      let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
    if json["code"] as? Int == -101 { return true }
    return url.host == "api.bilibili.com" && url.path == "/x/web-interface/nav" && json["code"] as? Int == 0
      && (json["data"] as? [String: Any])?["isLogin"] as? Bool == false
  }
  static let notification = Notification.Name("PiliNative.webSessionInvalidated")
  static func announce(_ owner: String) async {
    await MainActor.run { NotificationCenter.default.post(name: notification, object: owner) }
  }
}
