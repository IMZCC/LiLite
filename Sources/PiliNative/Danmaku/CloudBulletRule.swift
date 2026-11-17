import Foundation

struct CloudBulletRule: Codable, Identifiable, Equatable {
  let id: Int64, type: Int, filter: String
  var display: String { type == 1 ? Self.regexBody(filter) : filter }
  static func regexBody(_ raw: String) -> String {
    raw.count >= 2 && raw.first == "/" && raw.last == "/" ? String(raw.dropFirst().dropLast()) : raw
  }
  static func input(_ raw: String, type: Int, senderHash: Bool = false) throws -> String {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 4096 else { throw ServiceError("请输入有效的规则") }
    switch type {
    case 0: return value
    case 1:
      let expression = regexBody(value)
      guard !expression.isEmpty else { throw ServiceError("请输入正则表达式") }
      _ = try NSRegularExpression(pattern: expression, options: .caseInsensitive)
      return expression
    case 2 where senderHash:
      guard value.utf8.count <= 8, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else {
        throw ServiceError("发送者标识无效")
      }
      return value.lowercased()
    case 2:
      guard value.utf8.allSatisfy({ (48...57).contains($0) }), let uid = Int64(value), uid > 0 else { throw ServiceError("请输入有效的 UID") }
      return DanmakuStyle.senderHash(String(uid))
    default: throw ServiceError("不支持的规则类型")
    }
  }
}

struct CloudBulletMatcher {
  private let words: [String], patterns: [NSRegularExpression], senders: Set<String>
  init(_ rules: [CloudBulletRule]) {
    words = rules.filter { $0.type == 0 && !$0.filter.isEmpty }.map(\.filter)
    patterns = rules.filter { $0.type == 1 && !$0.display.isEmpty }.compactMap {
      try? NSRegularExpression(pattern: $0.display, options: .caseInsensitive)
    }
    senders = Set(rules.filter { $0.type == 2 }.map { $0.filter.lowercased() })
  }
  func hides(text: String, sender: String?) -> Bool {
    if let sender, senders.contains(sender.lowercased()) { return true }
    return words.contains(where: text.contains) || patterns.contains {
      $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
  }
}
