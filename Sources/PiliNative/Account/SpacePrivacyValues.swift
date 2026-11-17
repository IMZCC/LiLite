import Foundation

struct SpacePrivacyValues: Decodable {
  struct Field: Identifiable {
    let id: String, label: String, reverse: Bool
    init(_ id: String, _ label: String, _ reverse: Bool = false) {
      self.id = id; self.label = label; self.reverse = reverse
    }
  }
  static let sections: [(String,[Field])] = [
    ("空间展示", [Field("fav_video","收藏"), Field("bangumi","追番追剧"), Field("comic","追漫"),
      Field("coins_video","最近投币的视频"), Field("likes_video","最近点赞的视频"),
      Field("played_game","最近玩的游戏"), Field("dress_up","粉丝装扮")]),
    ("个人信息", [Field("disable_following","关注列表",true), Field("disable_show_fans","粉丝列表",true),
      Field("close_space_medal","佩戴的勋章",true), Field("only_show_wearing","所有粉丝勋章",true),
      Field("disable_show_school","学校",true)]),
    ("投稿列表", [Field("live_playback","直播回放"), Field("charge_video","包月充电专属视频"), Field("lesson_video","课堂视频")])
  ]

  enum Issue: Error { case conflict }
  let values: [String: Int]
  private struct Key: CodingKey {
    var stringValue: String
    init(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { return nil }
  }
  init(from d: Decoder) throws {
    let fields = Self.sections.flatMap { $0.1 }
    let c = try d.container(keyedBy: Key.self)
    values = Dictionary(uniqueKeysWithValues: fields.compactMap { f in
      let k = Key(stringValue: f.id)
      guard let i = try? c.decode(Int.self, forKey: k), (0...1).contains(i) else { return nil }
      return (f.id, i)
    })
  }
  static func merge(baseline: [String: Int], draft: [String: Int], latest: [String: Int]) throws -> [String: Int] {
    let keys = Set(sections.flatMap { $0.1.map(\.id) })
    let edited = draft.filter { keys.contains($0.key) && (0...1).contains($0.value) && baseline[$0.key] != $0.value }
    guard edited.allSatisfy({ latest[$0.key] == baseline[$0.key] || latest[$0.key] == $0.value }) else { throw Issue.conflict }
    return latest.filter { keys.contains($0.key) && (0...1).contains($0.value) }.merging(edited) { _, new in new }
  }
}
