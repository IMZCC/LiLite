import Foundation

// Keep source-specific rules in one place; hot and ranking never use the duration threshold.
struct RecommendationRules: Codable, Equatable {
  var minimumSeconds = 0, minimumViews = 0, minimumLikePercent = 0
  var titlePattern = "", zonePattern = ""
  var blockedCreators: Set<Int64> = []
  var exemptFollowed = true, filterRelated = true
  static let key = "feed.filter.v1"
  static let creatorLimit = 65_536
  private static let decoded = DecodedSettingCache<Self>()
  static func read(_ data: Data) -> Self {
    decoded.value(for: data) { (try? JSONDecoder().decode(Self.self, from: $0)) ?? Self() }
  }
  static func current(_ d: UserDefaults = .standard) -> Self {
    read(d.data(forKey: key) ?? Data())
  }
  func validate() throws {
    guard minimumSeconds >= 0, minimumViews >= 0, (0...100).contains(minimumLikePercent),
      titlePattern.utf8.count <= 4096, zonePattern.utf8.count <= 4096,
      blockedCreators.count <= Self.creatorLimit, blockedCreators.allSatisfy({ $0 > 0 })
    else { throw ServiceError("请检查筛选范围") }
    for pattern in [titlePattern, zonePattern] where !pattern.isEmpty {
      do { _ = try NSRegularExpression(pattern: pattern, options: .caseInsensitive) } catch {
        throw ServiceError("关键词表达式无效")
      }
    }
  }
  func save(_ d: UserDefaults = .standard) throws {
    try validate()
    d.set(try JSONEncoder().encode(self), forKey: Self.key)
  }
}

struct RecommendationFilter {
  enum Source { case feed, mobileFeed, hotOrRank, related }
  private let rules: RecommendationRules
  private let title, zone: NSRegularExpression?
  init(_ rules: RecommendationRules = .current()) {
    self.rules = rules
    func expression(_ s: String) -> NSRegularExpression? {
      s.isEmpty ? nil : try? NSRegularExpression(pattern: s, options: .caseInsensitive)
    }
    title = expression(rules.titlePattern)
    zone = expression(rules.zonePattern)
  }
  func includes(
    title label: String, zone partition: String?, seconds: Int?, views: Int?, likes: Int?,
    followed: Bool, creator: Int64? = nil, source: Source
  ) -> Bool {
    if let creator, rules.blockedCreators.contains(creator) { return false }
    if source == .related && !rules.filterRelated { return true }
    func matches(_ expression: NSRegularExpression?, _ s: String) -> Bool {
      expression?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
    // The mobile feed drops matching zones before its followed-creator exemption.
    // Web recommendations and related archives do not apply the zone rule.
    if source == .mobileFeed || source == .hotOrRank,
      let partition, matches(zone, partition) { return false }
    if (source == .feed || source == .mobileFeed) && followed && rules.exemptFollowed { return true }
    if matches(title, label) { return false }
    if source != .hotOrRank, let seconds, seconds > 0, seconds < rules.minimumSeconds {
      return false
    }
    if let views {
      if views >= 0 && views < rules.minimumViews { return false }
      if let likes,
        likes >= 0 && Double(likes) * 100 < Double(rules.minimumLikePercent) * Double(views)
      {
        return false
      }
    }
    return true
  }
}
