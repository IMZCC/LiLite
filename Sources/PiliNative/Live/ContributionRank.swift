import SwiftUI

struct LiveContributionRank: View {
  let room: LiveRoomIdentity
  enum Period: String, CaseIterable {
    case online_rank, daily_rank, weekly_rank, monthly_rank
    var title: String {
      switch self {
      case .online_rank: "在线"
      case .daily_rank: "今日"
      case .weekly_rank: "本周"
      case .monthly_rank: "本月"
      }
    }
    var mode: String {
      switch self {
      case .online_rank: "contribution_rank"
      case .daily_rank: "today_rank"
      case .weekly_rank: "current_week_rank"
      case .monthly_rank: "current_month_rank"
      }
    }
  }
  struct Payload: Decodable { let item: [Member]? }
  struct Member: Decodable {
    let uid: Int64?, name, face: String?, score: Int64?, uinfo: Info?
    struct Info: Decodable { let medal: Medal? }
    struct Medal: Decodable { let name: String?, level: Int? }
  }
  struct Position: Identifiable { let id: Int, member: Member }
  @EnvironmentObject private var accounts:AccountContext
  @State private var visited:Set<Period> = [.online_rank]
  @State private var tab = Period.online_rank
  var body: some View {
    VStack(spacing: 0) {
      ChipBar(items: Period.allCases, selection: $tab, title: \.title).padding(.vertical, 6)
      ZStack {
        ForEach(Period.allCases,id:\.self){ period in
          if visited.contains(period) {
            table(period).opacity(period==tab ? 1:0).allowsHitTesting(period==tab).accessibilityHidden(period != tab)
          }
        }
      }
    }.navigationTitle("直播贡献榜").onChange(of:tab){_,value in visited.insert(value)}
  }
  private func table(_ period:Period)->some View {
    let owner = accounts.state.active ?? ""
    return PageList(empty: "暂无上榜观众",autoMore:true,active:period==tab) { cursor in
        let api = BiliAPI.shared
        let p = Int(cursor ?? "1") ?? 1
        let page = try await api.read(
          "/xlive/general-interface/v1/rank/queryContributionRank",
          try await api.sign([
            "ruid": String(room.uid), "room_id": String(room.room_id), "page": String(p),
            "page_size": "100", "type": period.rawValue, "switch": period.mode, "platform": "web",
            "web_location": "444.8",
          ]), host: "api.live.bilibili.com", expectedAccount:owner, as: Payload.self)
        let members = (page.item ?? []).enumerated().map {
          Position(id: (p - 1) * 100 + $0.offset + 1, member: $0.element)
        }
        return Page(items: members, next: members.count == 100 ? String(p + 1) : nil)
      } row: { p in
        if let uid = p.member.uid, uid > 0 {
          PlainRowLink {
            CreatorSpace(mid: uid, name: p.member.name ?? "用户")
          } label: {
            label(p, showScore:period == .online_rank)
          }
        } else {
          label(p, showScore:period == .online_rank)
        }
      }.id("\(room.room_id):\(owner):\(period.rawValue)")
  }
  private func label(_ p: Position,showScore:Bool) -> some View {
    let medal = p.member.uinfo?.medal.flatMap { m -> String? in
      guard let name = m.name, !name.isEmpty else { return nil }
      return name + (m.level.map { " \($0)" } ?? "")
    }
    return RankedPersonRow(
      rank: p.id, avatar: p.member.face.flatMap(httpsURL), name: p.member.name ?? "匿名用户",
      note: medal,
      tag: showScore ? p.member.score.map { $0.formatted(.number.notation(.compactName)) } : nil,
      tagColor: .pink)
  }
}
