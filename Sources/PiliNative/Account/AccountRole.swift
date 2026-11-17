import Foundation

enum AccountRole: Int, CaseIterable, Codable, Identifiable {
  case main = 0
  case heartbeat = 1
  case recommend = 2
  case video = 3
  var id: Self { self }
  var title: String {
    switch self {
    case .main: return "主账号"
    case .heartbeat: return "记录观看"
    case .recommend: return "首页推荐"
    case .video: return "视频取流"
    }
  }
}
enum AccountUse {
  case role(AccountRole)
  case history
}
struct AccountRoutes: Codable, Equatable, Sendable {
  static let follow = "$main", guest = ""
  private var selected: [String: String] = [:]
  mutating func set(_ role: AccountRole, choice: String) {
    guard role != .main else { return }
    selected[String(role.rawValue)] = choice == Self.follow ? nil : choice
  }
  func privatePlaybackCopy() -> Self {
    var r = self
    r.set(.heartbeat, choice: Self.guest)
    return r
  }
  mutating func remove(_ uid: String) {
    for (k, v) in selected where v == uid { selected[k] = Self.guest }
  }
  func choice(_ role: AccountRole) -> String { selected[String(role.rawValue)] ?? Self.follow }
  func owner(_ use: AccountUse, main: String?, available: Set<String>) -> String? {
    func id(_ role: AccountRole) -> String? {
      let c = role == .main ? Self.follow : choice(role)
      let result = c == Self.follow ? main : (c == Self.guest ? nil : c)
      return result.flatMap { available.contains($0) ? $0 : nil }
    }
    switch use {
    case .role(let r): return id(r)
    case .history: return id(.heartbeat) ?? id(.main)
    }
  }
  static func service(_ path: String, host: String) -> AccountUse {
    if let role = services[host + path] { return .role(role) }
    if host == "api.bilibili.com" {
      switch path {
      case "/x/v2/reply/main": return .role(.heartbeat)
      case "/x/web-interface/history/cursor", "/x/web-interface/history/search",
        "/x/v2/history/shadow", "/x/v2/history/shadow/set", "/x/v2/history/clear",
        "/x/v2/history/delete":
        return .history
      default: break
      }
    }
    return .role(.main)
  }
}
