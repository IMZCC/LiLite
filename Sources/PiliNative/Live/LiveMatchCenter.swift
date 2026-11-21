import SwiftUI

// An official esports room's 赛程, 回放 and 选手评分, as the official client shows them in its
// match tabs. Bilibili's esports service (x/esports/...) answers without signing; a room is matched
// to its season through the contests that list it as their `live_room`.

/// One match ("contest") of a season.
struct EsportsContest: Decodable, Identifiable, Hashable {
  struct Team: Decodable, Hashable {
    let id: Int64?, name: String?, icon: String?
    var logo: URL? { EsportsContest.image(icon) }
  }
  struct Season: Decodable, Hashable { let id: Int64?, title: String? }
  struct Hottest: Decodable, Hashable { let nickname: String?, avg_grade: String? }
  let id: Int64
  let start: Int64?, end: Int64?
  let stage: String?
  let liveRoom: Int64?
  let playback: String?, highlights: String?
  let seasonID: Int64?
  /// 1 not started, 2 live, 3 finished.
  let status: Int
  let homeScore: Int?, awayScore: Int?
  let home: Team?, away: Team?
  let season: Season?
  let hottest: Hottest?

  private enum Keys: String, CodingKey {
    case id, start_time, end_time, game_stage, live_room, play_back, playback, collection_url,
      season_id, contest_status, home_score, away_score, home, away, season, hottest_player
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    id = try c.decode(Int64.self, forKey: .id)
    start = try? c.decodeIfPresent(Int64.self, forKey: .start_time)
    end = try? c.decodeIfPresent(Int64.self, forKey: .end_time)
    stage = try? c.decodeIfPresent(String.self, forKey: .game_stage)
    liveRoom = try? c.decodeIfPresent(Int64.self, forKey: .live_room)
    let back = (try? c.decodeIfPresent(String.self, forKey: .play_back)) ?? nil
    playback = back?.isEmpty == false ? back : (try? c.decodeIfPresent(String.self, forKey: .playback)) ?? nil
    highlights = try? c.decodeIfPresent(String.self, forKey: .collection_url)
    seasonID = try? c.decodeIfPresent(Int64.self, forKey: .season_id)
    status = ((try? c.decodeIfPresent(Int.self, forKey: .contest_status)) ?? nil) ?? 1
    homeScore = try? c.decodeIfPresent(Int.self, forKey: .home_score)
    awayScore = try? c.decodeIfPresent(Int.self, forKey: .away_score)
    home = try? c.decodeIfPresent(Team.self, forKey: .home)
    away = try? c.decodeIfPresent(Team.self, forKey: .away)
    season = try? c.decodeIfPresent(Season.self, forKey: .season)
    hottest = try? c.decodeIfPresent(Hottest.self, forKey: .hottest_player)
  }
  var date: Date? { start.flatMap { $0 > 0 ? Date(timeIntervalSince1970: Double($0)) : nil } }
  var replay: SharedLink? { playback.flatMap { $0.isEmpty ? nil : SharedLink.parse($0) } }
  var statusText: String { [1: "未开始", 2: "直播中", 3: "已结束"][status] ?? "" }
  /// Team logos come as site-relative paths.
  static func image(_ path: String?) -> URL? {
    guard let path, !path.isEmpty else { return nil }
    if let url = httpsURL(path) { return url }
    return path.hasPrefix("/") ? httpsURL("https://i0.hdslb.com" + path) : nil
  }
}

/// A contest's player ratings for one game of the series (x/esports/grade/info).
struct EsportsGrades: Decodable {
  struct Player: Decodable, Identifiable, Hashable {
    let player_id: Int64
    let nickname: String?, position: String?, portrait: String?, hero_photo: String?
    let avg_grade: String?, grade_users: Int?, hot_remark: String?
    let kill: Int?, death: Int?, assist: Int?
    var id: Int64 { player_id }
    var score: Double? { avg_grade.flatMap(Double.init) }
  }
  struct Team: Decodable, Identifiable {
    let name: String?, logo: String?
    let player_grade_detail: [Player]?
    var id: String { name ?? "" }
    var players: [Player] { player_grade_detail ?? [] }
  }
  let current_bo: Int?
  let contest_status: Int?
  let teams: [Team]?
}

enum EsportsService {
  /// The contest of this room nearest to now, looked up among the contests a week either side.
  static func contest(forRoom room: Int64) async throws -> EsportsContest? {
    struct Page: Decodable { let contests: [EsportsContest]? }
    let now = Int64(Date().timeIntervalSince1970)
    var found: [EsportsContest] = []
    for page in 1...3 {
      let result = try await BiliAPI.shared.read(
        "/x/esports/match/search/list",
        ["type": "0", "stime": String(now - 7 * 86_400), "etime": String(now + 7 * 86_400), "sort": "1",
         "pn": String(page), "ps": "50"], as: Page.self)
      let rows = result.contests ?? []
      found += rows.filter { $0.liveRoom == room }
      if rows.count < 50 || !found.isEmpty { break }
    }
    // A match on air first, then whichever starts closest to now.
    return found.first { $0.status == 2 }
      ?? found.min { abs(($0.start ?? 0) - now) < abs(($1.start ?? 0) - now) }
  }
  struct Schedule: Decodable {
    let history: [EsportsContest]?, future: [EsportsContest]?
    let prev: Int64?, next: Int64?
  }
  /// A season's contests around a cursor (`prev` for earlier ones, `next` for later).
  static func schedule(season: Int64, prev: Int64? = nil, next: Int64? = nil) async throws -> Schedule {
    var q = ["sid": String(season), "ps": "50"]
    if let prev { q["prev"] = String(prev) }
    if let next { q["next"] = String(next) }
    return try await BiliAPI.shared.read("/x/esports/component/contests/link", q, as: Schedule.self)
  }
  static func grades(contest: Int64, bo: Int) async throws -> EsportsGrades {
    try await BiliAPI.shared.read(
      "/x/esports/grade/info", ["cid": String(contest), "bo": String(bo)], as: EsportsGrades.self)
  }
}

/// The season a match room carries: its contests, loaded once and shared by the room's 赛程, 回放
/// and 选手评分 tabs.
@MainActor @Observable final class LiveMatchStore {
  let contest: EsportsContest
  private(set) var rows: [EsportsContest] = []
  private(set) var earlier: Int64?
  private(set) var later: Int64?
  private(set) var loading = false
  private(set) var issue: String?
  private var started = false
  init(contest: EsportsContest) { self.contest = contest }
  var finished: [EsportsContest] {
    rows.filter { $0.status == 3 && $0.replay != nil }.sorted { ($0.start ?? 0) > ($1.start ?? 0) }
  }
  /// Matches that have started, newest first: the ones with ratings.
  var rated: [EsportsContest] { rows.filter { $0.status != 1 }.sorted { ($0.start ?? 0) > ($1.start ?? 0) } }
  /// By day.
  var days: [(day: Date, rows: [EsportsContest])] {
    let calendar = Calendar.current
    let groups = Dictionary(grouping: rows) { calendar.startOfDay(for: $0.date ?? .distantPast) }
    return groups.keys.sorted().map { ($0, groups[$0]!.sorted { ($0.start ?? 0) < ($1.start ?? 0) }) }
  }
  func start() async {
    guard !started else { return }
    started = true
    await load()
  }
  func load(prev: Int64? = nil, next: Int64? = nil) async {
    guard let season = contest.seasonID ?? contest.season?.id else {
      issue = "未找到赛事信息"
      return
    }
    loading = true
    issue = nil
    defer { loading = false }
    do {
      let page = try await EsportsService.schedule(season: season, prev: prev, next: next)
      var seen = Set(rows.map(\.id))
      rows += ((page.history ?? []) + (page.future ?? [])).filter { seen.insert($0.id).inserted }
      let first = prev == nil && next == nil
      if prev != nil || first { earlier = (page.prev ?? -1) > 0 ? page.prev : nil }
      if next != nil || first { later = (page.next ?? -1) > 0 ? page.next : nil }
    } catch {
      if !Task.isCancelled { issue = error.localizedDescription }
      started = rows.isEmpty ? false : started
    }
  }
}

/// The tabs a match room adds after 互动.
enum LiveMatchTab: String, CaseIterable, Identifiable {
  case schedule = "赛程", replay = "回放", grades = "选手评分"
  var id: Self { self }
}

/// One of the match tabs, on the room's dark page.
struct LiveMatchPane: View {
  let store: LiveMatchStore
  let tab: LiveMatchTab
  /// Stops the room's stream when a replay or a match page is opened from here.
  let pauseLive: () -> Void
  @State private var gradeContest: EsportsContest?
  var body: some View {
    Group {
      switch tab {
      case .schedule: schedule
      case .replay: replays
      case .grades:
        if let pick = gradeContest ?? (store.contest.status != 1 ? store.contest : store.rated.first) {
          EsportsGradeBoard(contests: store.rated.isEmpty ? [pick] : store.rated,
            selected: Binding(get: { pick }, set: { gradeContest = $0 }))
        } else if store.loading {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ContentUnavailableView("暂无选手评分", systemImage: "star.leadinghalf.filled",
            description: Text("比赛开始后可查看选手评分"))
        }
      }
    }
    .scrollContentBackground(.hidden)
    .task { await store.start() }
  }
  private var schedule: some View {
    ScrollViewReader { proxy in
      List {
        if store.earlier != nil {
          Button("加载更早的比赛") { Task { await store.load(prev: store.earlier) } }
            .disabled(store.loading).listRowBackground(Color.clear)
        }
        ForEach(store.days, id: \.day) { day in
          Section(day.day.formatted(.dateTime.month().day().weekday(.abbreviated))) {
            ForEach(day.rows) { row in
              NavigationLink { MatchDetailView(id: row.id).onAppear(perform: pauseLive) } label: {
                EsportsContestRow(contest: row, current: row.id == store.contest.id)
              }
              .id(row.id)
              .listRowBackground(row.id == store.contest.id ? Color.white.opacity(0.06) : Color.clear)
            }
          }
        }
        if store.later != nil {
          Button("加载之后的比赛") { Task { await store.load(next: store.later) } }
            .disabled(store.loading).listRowBackground(Color.clear)
        }
        footer
      }
      .listStyle(.plain)
      .onAppear { proxy.scrollTo(store.contest.id, anchor: .center) }
      .onChange(of: store.rows.count) { _, _ in
        // Open on the room's own match, as the official schedule does.
        proxy.scrollTo(store.contest.id, anchor: .center)
      }
    }
  }
  private var replays: some View {
    List {
      ForEach(store.finished) { row in
        if let link = row.replay {
          NavigationLink { LinkDestination(item: link).onAppear(perform: pauseLive) } label: {
            EsportsContestRow(contest: row, current: false, replay: true)
          }
          .listRowBackground(Color.clear)
        }
      }
      if store.finished.isEmpty && !store.loading && store.issue == nil {
        Text("暂无回放").foregroundStyle(.secondary).listRowBackground(Color.clear)
      }
      footer
    }
    .listStyle(.plain)
  }
  @ViewBuilder private var footer: some View {
    if let issue = store.issue {
      PageFailure(message: issue) { Task { await store.load() } }.listRowBackground(Color.clear)
    } else if store.loading && store.rows.isEmpty {
      ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
    }
  }
}

/// A match: when and which stage, the two teams with their logos, the score (or VS) and status.
private struct EsportsContestRow: View {
  let contest: EsportsContest
  let current: Bool
  var replay = false
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        if let date = contest.date {
          Text(date, format: replay ? .dateTime.month().day().hour().minute() : .dateTime.hour().minute())
            .monospacedDigit()
        }
        if let stage = contest.stage, !stage.isEmpty { Text(stage) }
        Spacer(minLength: 4)
        if replay {
          Label("回放", systemImage: "play.rectangle").labelStyle(.titleAndIcon).foregroundStyle(.tint)
        } else if !contest.statusText.isEmpty {
          Text(current && contest.status == 2 ? "本直播间" : contest.statusText)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(contest.status == 2 ? Color.white : Color.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(contest.status == 2 ? Color.pink : Color(uiColor: .tertiarySystemFill), in: Capsule())
        }
      }
      .font(.caption).foregroundStyle(.secondary)
      HStack(spacing: 10) {
        team(contest.home, trailing: false)
        Text(contest.status == 1 ? "VS" : "\(max(0, contest.homeScore ?? 0)) : \(max(0, contest.awayScore ?? 0))")
          .font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
          .frame(minWidth: 64)
        team(contest.away, trailing: true)
      }
      if let hot = contest.hottest, let name = hot.nickname, let grade = hot.avg_grade, !grade.isEmpty {
        Text("热门选手 \(name) · \(grade) 分").font(.caption2).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }
  private func team(_ team: EsportsContest.Team?, trailing: Bool) -> some View {
    HStack(spacing: 6) {
      if trailing { Spacer(minLength: 0) }
      if trailing { Text(team?.name ?? "待定").font(.subheadline.weight(.semibold)).lineLimit(1) }
      SiteThumbnail(url: team?.logo) { $0.resizable().scaledToFit() } placeholder: {
        Image(systemName: "shield.lefthalf.filled").resizable().scaledToFit().foregroundStyle(.quaternary)
      }
      .frame(width: 28, height: 28).accessibilityHidden(true)
      if !trailing { Text(team?.name ?? "待定").font(.subheadline.weight(.semibold)).lineLimit(1) }
      if !trailing { Spacer(minLength: 0) }
    }
    .frame(maxWidth: .infinity)
  }
}

/// The ratings of one match: a match and game picker, then each team's players with their
/// average score, how many rated, the hero and KDA. Rating itself is the official page's.
private struct EsportsGradeBoard: View {
  let contests: [EsportsContest]
  @Binding var selected: EsportsContest
  @State private var bo = 1
  @State private var grades: EsportsGrades?
  @State private var issue: String?
  @State private var loading = false
  var body: some View {
    List {
      Section {
        if contests.count > 1 {
          Picker("比赛", selection: $selected) {
            ForEach(contests) { c in
              Text("\(c.home?.name ?? "?") vs \(c.away?.name ?? "?") · \(c.stage ?? "")").tag(c)
            }
          }
        }
        if let games = grades?.current_bo, games > 1 {
          Picker("局数", selection: $bo) {
            ForEach(1...games, id: \.self) { Text("第 \($0) 局").tag($0) }
          }
          .pickerStyle(.segmented)
        }
        if let url = URL(string: "https://www.bilibili.com/h5/match/data/grade-list/\(selected.id)?bo=\(bo)") {
          NavigationLink { SitePage(url: url) } label: {
            Label("去评分", systemImage: "star.bubble")
          }
        }
      }
      .listRowBackground(Color.white.opacity(0.05))
      if let issue {
        PageFailure(message: issue) { Task { await load() } }.listRowBackground(Color.clear)
      }
      ForEach(grades?.teams ?? []) { team in
        Section(team.name ?? "") {
          if team.players.isEmpty { Text("暂无评分").foregroundStyle(.secondary) }
          ForEach(team.players) { player in EsportsPlayerRow(player: player) }
        }
        .listRowBackground(Color.clear)
      }
      if loading && grades == nil { ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear) }
    }
    .listStyle(.plain)
    .task(id: "\(selected.id):\(bo)") { await load() }
    .onChange(of: selected.id) { _, _ in bo = 1; grades = nil }
  }
  @MainActor private func load() async {
    loading = true
    issue = nil
    defer { loading = false }
    do {
      let result = try await EsportsService.grades(contest: selected.id, bo: bo)
      try Task.checkCancellation()
      grades = result
      // Open on the latest game played, as the official board does.
      if bo == 1, let last = result.current_bo, last > 1, grades?.teams?.allSatisfy({ $0.players.isEmpty }) != false {
        bo = last
      }
    } catch {
      if !Task.isCancelled { issue = error.localizedDescription }
    }
  }
}

private struct EsportsPlayerRow: View {
  let player: EsportsGrades.Player
  var body: some View {
    HStack(spacing: 12) {
      ZStack(alignment: .bottomTrailing) {
        SiteThumbnail(url: player.portrait.flatMap(httpsURL)) { $0.resizable().scaledToFill() } placeholder: {
          Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.quaternary)
        }
        .frame(width: 44, height: 44).clipShape(Circle())
        if let hero = player.hero_photo.flatMap(httpsURL) {
          SiteThumbnail(url: hero) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
            .frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color(uiColor: .systemBackground), lineWidth: 1.5))
            .offset(x: 4, y: 4)
        }
      }
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(player.nickname ?? "选手").font(.subheadline.weight(.semibold))
          if let position = player.position, !position.isEmpty {
            Text(position).font(.caption2).foregroundStyle(.secondary)
          }
        }
        if let k = player.kill, let d = player.death, let a = player.assist {
          Text("KDA \(k)/\(d)/\(a)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        if let remark = player.hot_remark, !remark.isEmpty {
          Text(remark).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 2) {
        Text(player.score.map { String(format: "%.1f", $0) } ?? "—")
          .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
          .foregroundStyle(scoreTint)
        if let users = player.grade_users, users > 0 {
          Text("\(users.formatted(.number.notation(.compactName))) 人评分").font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }
  private var scoreTint: Color {
    guard let s = player.score else { return .secondary }
    return s >= 8 ? .orange : s >= 5 ? .primary : .secondary
  }
}
