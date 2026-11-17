import Foundation

struct ReplyFilterRules: Codable, Equatable {
  static let key = "reply.filters.v1"
  var mentionsOnly = false, goods = false, duplicateIntro = false
  var threshold: Int? = nil
  var pattern = ""
  var lines = 6
  static func current(_ d: UserDefaults = .standard) -> Self {
    guard let bytes = d.data(forKey: key),
      let rules = try? JSONDecoder().decode(Self.self, from: bytes),
      (try? rules.validate()) != nil
    else { return .init() }
    return rules
  }
  func addingLiteral(_ selection:String)throws->Self{
    guard !selection.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw ServiceError("请先选择要过滤的文字")}
    let literal=NSRegularExpression.escapedPattern(for:selection)
    var copy=self;copy.pattern=pattern.isEmpty ? literal:pattern+"|"+literal;try copy.validate();return copy
  }
  func validate() throws {
    guard threshold.map({ $0 >= 0 }) ?? true, lines >= 0, pattern.utf8.count <= 4096 else {
      throw ServiceError("请检查评论过滤设置")
    }
    if !pattern.isEmpty { _ = try NSRegularExpression(pattern: pattern, options: .caseInsensitive) }
  }
  func save(_ d: UserDefaults = .standard) throws {
    try validate()
    d.set(try JSONEncoder().encode(self), forKey: Self.key)
  }
}

struct ReplyFilter {
  let rules: ReplyFilterRules, blocked: Set<Int64>, intro: String?
  private let regex: NSRegularExpression?
  init(rules: ReplyFilterRules, blocked: Set<Int64>, intro: String?) {
    self.rules = rules
    self.blocked = blocked
    self.intro = intro?.trimmingCharacters(in: .whitespacesAndNewlines)
    regex =
      rules.pattern.isEmpty
      ? nil : try? NSRegularExpression(pattern: rules.pattern, options: .caseInsensitive)
  }
  func hides(
    author: Int64?, body: String, mentions: Set<String>, hasMedia: Bool, hasGoods: Bool,
    nested: Bool
  ) -> Bool {
    if let author, blocked.contains(author) { return true }
    if let limit = rules.threshold, mentions.count >= limit { return true }
    if rules.goods && (hasGoods || body.contains("https://gaoneng.bilibili.com/tetris")) {
      return true
    }
    if rules.duplicateIntro, let intro, !intro.isEmpty,
      body.trimmingCharacters(in: .whitespacesAndNewlines) == intro
    {
      return true
    }
    if let regex, regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil {
      return true
    }
    guard rules.mentionsOnly, !hasMedia, !mentions.isEmpty else { return false }
    var text = body[...]
    if nested {
      guard let colon = text.firstIndex(of: ":") else { return false }
      text = text[text.index(after: colon)...]
    }
    var found = false
    while let first = text.first {
      if first == " " || first == "\n" {
        text = text.dropFirst()
        continue
      }
      guard first == "@" else { return false }
      text = text.dropFirst()
      let name = text.prefix { $0 != " " && $0 != "\n" && $0 != "@" }
      guard !name.isEmpty, mentions.contains(String(name)) else { return false }
      found = true
      text = text[name.endIndex...]
    }
    return found
  }
}
