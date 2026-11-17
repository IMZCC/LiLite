import Foundation

struct SponsorCategory: Identifiable {
  let id: String, title: String, rgb: String, actions: [String]
  init(_ id: String, _ title: String, _ rgb: String, _ actions: [String]) {
    self.id = id
    self.title = title
    self.rgb = rgb
    self.actions = actions
  }
  static let all: [Self] = [
    .init("sponsor", "赞助", "00d400", ["skip", "mute", "full"]),
    .init("selfpromo", "推广", "ffff00", ["skip", "mute", "full"]),
    .init("exclusive_access", "品牌合作", "008a5c", ["full"]),
    .init("interaction", "三连提醒", "cc00ff", ["skip", "mute"]),
    .init("poi_highlight", "精彩时刻", "ff1684", ["poi"]),
    .init("intro", "开场动画", "00ffff", ["skip", "mute"]),
    .init("outro", "片尾", "0202ed", ["skip", "mute"]),
    .init("preview", "预览", "008fd6", ["skip", "mute"]),
    .init("padding", "填充内容", "222222", ["skip"]),
    .init("filler", "离题", "7300ff", ["skip", "mute"]),
    .init("music_offtopic", "非音乐", "ff9900", ["skip"]),
    .init("jumpscare", "惊吓", "e53935", ["mute"]),
  ]
}
struct SponsorSegment: Decodable, Identifiable {
  let category: String, actionType: String?, segment: [Double], UUID: String
  var id: String { UUID }
  var detail: SponsorCategory? { SponsorCategory.all.first { $0.id == category } }
  var valid: Bool {
    detail != nil && segment.count == 2 && segment.allSatisfy { $0.isFinite && $0 >= 0 }
      && segment[0] <= segment[1]
  }
}
struct SponsorRules: Codable, Equatable {
  static let key = "sponsor.rules"
  var modes = [Int](repeating: 1, count: SponsorCategory.all.count),
    colors = [String](repeating: "", count: SponsorCategory.all.count)
  var minimum = 0.0, toast = true, track = true
  static func legacy(_ auto: Bool?) -> Self {
    var r = Self()
    // Preserve the old native switch if it was expressly changed.
    if let auto {
      r.modes = Array(repeating: 2, count: SponsorCategory.all.count)
      r.modes[0] = auto ? 0 : 2
    }
    return r
  }
  static func current(_ d: UserDefaults = .standard) -> Self {
    if let raw = d.data(forKey: key), let r = try? JSONDecoder().decode(Self.self, from: raw),
      (try? r.validate()) != nil
    {
      return r
    }
    return legacy(d.object(forKey: "sponsor.auto") as? Bool)
  }
  func validate() throws {
    guard modes.count <= SponsorCategory.all.count, modes.allSatisfy((0...4).contains),
      colors.count == SponsorCategory.all.count,
      colors.allSatisfy({
        $0.isEmpty
          || $0.count == 6
            && $0.utf8.allSatisfy {
              (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }
      }),
      minimum.isFinite, minimum >= 0
    else { throw ServiceError("空降设置无效") }
  }
  func padded() -> Self {
    var r = self
    r.modes += Array(repeating: 1, count: max(0, SponsorCategory.all.count - r.modes.count))
    return r
  }
  func save(_ d: UserDefaults = .standard) throws {
    try validate()
    d.set(try JSONEncoder().encode(padded()), forKey: Self.key)
  }
  func mode(_ s: SponsorSegment) -> Int {
    guard s.valid, let i = SponsorCategory.all.firstIndex(where: { $0.id == s.category }) else {
      return 4
    }
    let m = i < modes.count ? modes[i] : 1
    return m == 4
      ? 4 : s.segment[0] == s.segment[1] || s.segment[1] - s.segment[0] < minimum ? 3 : m
  }
  func color(_ s: SponsorSegment) -> String {
    guard let i = SponsorCategory.all.firstIndex(where: { $0.id == s.category }) else {
      return "888888"
    }
    return colors.indices.contains(i) && !colors[i].isEmpty ? colors[i] : SponsorCategory.all[i].rgb
  }
}
struct SponsorVisits {
  private var seen = Set<String>(), active: String?
  mutating func next(_ rows: [SponsorSegment], time: Double, rules: SponsorRules) -> SponsorSegment?
  {
    let candidates = rows.filter {
      $0.valid && $0.segment[0] <= time && time < $0.segment[1] && rules.mode($0) <= 1
    }
    guard let first = candidates.first(where: { rules.mode($0) == 0 || !seen.contains($0.id) })
    else {
      if !candidates.contains(where: { $0.id == active }) { active = nil }
      return nil
    }
    guard first.id != active else { return nil }
    active = first.id
    seen.insert(first.id)
    return first
  }
}
