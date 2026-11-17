import Foundation

enum MobileDeviceID {
  static let guestKey = "account.guestDevice"
  private static let lock = NSLock()
  static func valid(_ v: String) -> Bool {
    (1...256).contains(v.utf8.count) && v.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
  }
  static func guest(_ d: UserDefaults = .standard) -> String {
    lock.lock(); defer { lock.unlock() }
    if let saved = d.string(forKey: guestKey), valid(saved) { return saved }
    let install = UUID().uuidString
    d.set(install, forKey: guestKey)
    return install
  }
  static func use(_ accountValue: String?, defaults: UserDefaults = .standard) -> String {
    accountValue.flatMap { valid($0) ? $0 : nil } ?? guest(defaults)
  }
  static func forRead(host: String, path: String) -> Bool {
    (host == "app.bilibili.com" && path == "/x/v2/feed/index") ||
    (host == "api.live.bilibili.com" && ["/xlive/app-interface/v2/index/feed", "/xlive/app-interface/v2/second/getList"].contains(path))
  }
}
