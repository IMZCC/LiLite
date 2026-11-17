import Foundation

extension Notification.Name {
  static let piliUnreadChanged = Notification.Name("pili.unread.autorefresh")
}
enum UnreadKind: Int, CaseIterable, Identifiable {
  case pm, reply, at, like, system
  var id: Self { self }
  var bit: Int { 1 << rawValue }
  var label: String {
    switch self {
    case .pm: "私信"
    case .reply: "回复我的"
    case .at: "@我"
    case .like: "收到的赞"
    case .system: "系统通知"
    }
  }
}
struct UnreadTotals {
  static let allMask = 31
  static func visibleMask(_ value: Int, hideLikes: Bool) -> Int {
    (value & allMask) & (hideLikes ? ~UnreadKind.like.bit : allMask)
  }
  static func sum(_ values: [Int64]) -> Int64 {
    values.reduce(0) { a, b in
      let q = a.addingReportingOverflow(max(0, b))
      return q.overflow ? Int64.max : q.partialValue
    }
  }
  static func messages(_ mask: Int, _ direct: [String: Int64], _ notices: [String: Int64]) -> Int64
  {
    var included = [Int64]()
    if mask & UnreadKind.pm.bit != 0 {
      for key in [
        "follow_unread", "unfollow_unread", "biz_msg_follow_unread", "biz_msg_unfollow_unread",
        "unfollow_push_msg", "custom_unread",
      ] { included.append(direct[key] ?? 0) }
    }
    for (kind, key) in [
      (UnreadKind.reply, "reply"), (.at, "at"), (.like, "like"), (.system, "sys_msg"),
    ] where mask & kind.bit != 0 { included.append(notices[key] ?? 0) }
    return sum(included)
  }
  static func label(_ count: Int64, mode: Int) -> String? {
    guard count > 0 else { return nil }
    switch mode {
    case 1: return "•"
    case 2: return count > 99 ? "99+" : String(count)
    default: return nil
    }
  }
}
struct IMUnreadFields: Decodable {
  let values: [String: Int64]
  struct Key: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    var v = [String: Int64]()
    for key in c.allKeys {
      if let n = try? c.decode(Int64.self, forKey: key) {
        v[key.stringValue] = n
      } else if let s = try? c.decode(String.self, forKey: key), let n = Int64(s) {
        v[key.stringValue] = n
      }
    }
    values = v
  }
}
