import SwiftUI

struct SupporterRanks: View {
  struct Response: Decodable {
    struct Level: Decodable, Identifiable {
      let privilege_type: Int, name: String?, member_total: Int?
      var id: Int { privilege_type }
    }
    struct Supporter: Decodable, Identifiable {
      let mid: Int64, nickname, avatar: String?, day: Int?
      var id: Int64 { mid }
    }
    let rank_info: [Supporter]?, level_info: [Level]?, privilege_type: Int?
  }
  private struct Ranked: Identifiable { let index: Int, person: Response.Supporter; var id: Int64 { person.mid } }
  let mid: Int64
  var name: String? = nil, total: Int? = nil
  @EnvironmentObject private var accounts: AccountContext
  @State private var tier: Int?
  @State private var visited = Set([-1])
  @State private var tops: [Int: Int] = [:]
  @State private var levels: [Response.Level] = []
  private var heading: String {
    let prefix = name.map { $0 + "的" } ?? ""
    let suffix = total.map { "（" + String($0) + "）" } ?? ""
    return prefix + "充电排行榜" + suffix
  }
  var body: some View {
    VStack(spacing: 0) {
      if !levels.isEmpty {
        let keys = levels.enumerated().map { $0.offset == 0 ? -1 : $0.element.id }
        ChipBar(
          items: keys,
          selection: Binding(get: { tier ?? -1 }, set: { key in
            visited.insert(key); tier = key == -1 ? nil : key
          }),
          title: { key in
            let level = key == -1 ? levels.first : levels.first { $0.id == key }
            return (level?.name ?? "充电") + " " + String(level?.member_total ?? 0)
          },
          reselect: { tops[tier ?? -1, default: 0] &+= 1 }
        ).padding(.vertical, 6)
      }
      ZStack {
        ForEach(visited.sorted(), id: \.self) { key in
          list(key).opacity(key == (tier ?? -1) ? 1 : 0)
            .accessibilityHidden(key != (tier ?? -1)).allowsHitTesting(key == (tier ?? -1))
        }
      }.id(accounts.state.active)
    }.onChange(of: accounts.state.active) { _, _ in
      visited = [-1]; tier = nil; levels = []; tops = [:]
    }.navigationTitle(heading).toolbar {
      if mid > 0, let url = URL(string: "https://member.bilibili.com/mall/upower-pay?mid=" + String(mid) + "&oid=" + String(mid)) {
        NavigationLink { DeferredPage { SitePage(url: url) } } label: { Label("充电", systemImage: "bolt.fill") }
      }
    }
  }
  private func list(_ key: Int) -> some View {
    let selected: Int? = key == -1 ? nil : key
    return PageList(empty: "暂无上榜成员", active: selected == tier, scrollToTopRequest: tops[key] ?? 0) { c in
        let viewer = accounts.state.active
        let p = Int(c ?? "1") ?? 1
        var q = [
          "up_mid": String(mid), "pn": String(p), "ps": "100", "mobi_app": "web",
          "web_location": "333.1196",
        ]
        q["privilege_type"] = selected.map(String.init)
        let r = try await BiliAPI.shared.read("/x/upower/up/member/rank/v2", q, expectedAccount: viewer ?? "", as: Response.self)
        try Task.checkCancellation()
        guard viewer == accounts.state.active else { throw CancellationError() }
        if selected == nil, p == 1 { levels = (r.level_info ?? []).count > 1 ? (r.level_info ?? []) : [] }
        let items = r.rank_info ?? []
        return Page(items: items.enumerated().map { Ranked(index: $0.offset + 1, person: $0.element) }, next: nil)
      } row: { rank in
        let u = rank.person
        PlainRowLink {
          CreatorSpace(mid: u.mid, name: u.nickname ?? "用户")
        } label: {
          RankedPersonRow(
            rank: rank.index, avatar: u.avatar.flatMap(httpsURL), name: u.nickname ?? "用户",
            note: u.day.map { "已充电 \($0) 天" })
        }
      }
  }
}
