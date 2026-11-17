import SwiftUI

extension BiliAPI {
  func homeSeasons(cinema: Bool, page: Int, owner: String) async throws -> Page<Season> {
    struct Result: Decodable { let list: [Season]?, total: Int?, has_next: Int? }
    var q = Dictionary(
      uniqueKeysWithValues: [
        "season_version", "spoken_language_type", "area", "is_finish", "copyright", "season_status",
        "season_month", "year", "style_id",
      ].map { ($0, "-1") })
    for (key, value) in [
      "st": "1", "order": "3", "sort": "0", "season_type": "1", "pagesize": "20", "type": "1",
      "page": String(page),
    ] { q[key] = value }
    if cinema { q["index_type"] = "102" }
    let r = try await read("/pgc/season/index/result", q, expectedAccount: owner, as: Result.self)
    let rows = r.list ?? []
    return .init(
      items: rows,
      next: !rows.isEmpty
        && (r.has_next.map { $0 != 0 } ?? r.total.map { page * 20 < $0 } ?? (rows.count == 20))
        ? String(page + 1) : nil)
  }
  func seasonUpdates(_ kind: Int, owner: String) async throws -> [SeasonSchedule.Day] {
    try await read(
      "/pgc/web/timeline", ["types": String(kind), "before": "6", "after": "6"],
      expectedAccount: owner, as: [SeasonSchedule.Day].self)
  }
}

struct SeasonTile: View {
  let season: Season
  var body: some View {
    NavigationLink {
      SeasonView(season: season)
    } label: {
      VStack(alignment: .leading, spacing: 6) {
        Rectangle().fill(.quaternary).aspectRatio(3 / 4, contentMode: .fit)
          .overlay {
            SiteThumbnail(url: httpsURL(season.cover)) {
              $0.resizable().scaledToFill()
            } placeholder: {
              Color.clear
            }
          }
          .overlay(alignment: .topTrailing) {
            if let badge = season.badge, !badge.isEmpty {
              Text(badge).font(.caption2.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.pink, in: Capsule()).padding(6)
            }
          }
          .overlay(alignment: .bottomLeading) {
            if let info = season.watchLabel {
              Text(info).font(.caption2.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                .padding(.horizontal, 7).padding(.top, 16).padding(.bottom, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                  LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            }
          }
          .clipped()
          .clipShape(RoundedRectangle(cornerRadius: NativeGlass.thumbRadius, style: .continuous))
        Text(season.title).font(.subheadline.weight(.medium)).lineLimit(2)
          .multilineTextAlignment(.leading).foregroundStyle(.primary)
        let labels = season.cardLabels.filter { $0 != season.badge }
        if !labels.isEmpty {
          Text(labels.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .seasonCover(season.cover)
  }
}

/// Section title with an optional trailing "more" link, shared by the PGC home sections.
private struct PGCSectionHeader<Destination: View>: View {
  let title: String
  var more: String? = nil
  @ViewBuilder var destination: () -> Destination
  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title).font(.title3.weight(.semibold))
      Spacer()
      if let more {
        NavigationLink(destination: destination) {
          HStack(spacing: 2) {
            Text(more)
            Image(systemName: "chevron.right").font(.caption2.weight(.bold))
          }.font(.subheadline)
        }.buttonStyle(.plain).foregroundStyle(.secondary)
      }
    }
  }
}

struct PGCHome: View {
  let cinema: Bool
  @AppStorage("discovery.pgcTimeline") private var timeline = true
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    let reader = accounts.state.owner(.role(.recommend)) ?? ""
    let header = AnyView(
      VStack(alignment: .leading, spacing: 24) {
        if let uid = accounts.state.active {
          SeasonSubscriptions(uid: uid, cinema: cinema).id(uid + String(cinema))
        }
        if !cinema && timeline {
          HomeSeasonSchedule(owner: accounts.state.active ?? "").id(accounts.state.active)
        }
        PGCSectionHeader(title: cinema ? "影视推荐" : "番剧推荐", more: "索引") {
          SeasonCatalog(initialType: cinema ? 102 : 1)
        }
      }.padding(.top, 4))
    PageList(empty: "暂无推荐", grid: true, autoMore: true, heading: header) { cursor in
      try await BiliAPI.shared.homeSeasons(
        cinema: cinema, page: Int(cursor ?? "1") ?? 1, owner: reader)
    } row: { item in
      SeasonTile(season: item)
    }.id(reader)
  }
}

private struct SeasonSubscriptions: View {
  let uid: String, cinema: Bool
  @State private var rows = [Season]()
  @State private var page = 1
  @State private var total: Int?
  @State private var busy = false
  @State private var ended = false
  @State private var message: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      PGCSectionHeader(
        title: cinema ? "我的追剧" : "我的追番", more: total.map { "全部 \($0)" } ?? "全部"
      ) {
        FollowedSeasons(uid: uid, initialType: cinema ? 2 : 1)
      }
      if let message {
        HStack {
          Text(message).foregroundStyle(.secondary).font(.caption)
          Button("重试") { Task { await more() } }.font(.caption)
        }
      }
      if rows.isEmpty && ended { Text("暂无订阅").font(.caption).foregroundStyle(.secondary) }
      ScrollView(.horizontal) {
        LazyHStack(alignment: .top, spacing: 12) {
          ForEach(rows) { item in SeasonTile(season: item).frame(width: 108) }
          if busy {
            ProgressView()
          } else if !ended && !rows.isEmpty && message == nil {
            Color.clear.frame(width: 1, height: 1).id(page).onAppear { Task { await more() } }
          }
        }
      }.scrollIndicators(.hidden).scrollClipDisabled()
    }.task { if rows.isEmpty && !ended { await more() } }
  }
  @MainActor private func more() async {
    guard !busy && !ended else { return }
    busy = true
    message = nil
    defer { busy = false }
    do {
      let r = try await BiliAPI.shared.read(
        "/x/space/bangumi/follow/list",
        ["vmid": uid, "type": cinema ? "2" : "1", "pn": String(page), "ps": "15"],
        expectedAccount: uid, as: FollowedSeasons.ListResult.self)
      try Task.checkCancellation()
      let slice = r.list ?? []
      var seen = Set(rows.map(\.id))
      rows.append(contentsOf: slice.filter { seen.insert($0.id).inserted })
      total = r.total
      ended = slice.isEmpty || (total.map { page * 15 >= $0 } ?? (slice.count < 15))
      page += 1
    } catch { if !Task.isCancelled { message = error.localizedDescription } }
  }
}

private struct HomeSeasonSchedule: View {
  let owner: String
  @State private var days = [SeasonSchedule.Day]()
  @State private var selected: Int?
  @State private var reload = 0
  @State private var failure: String?
  @State private var loaded = false
  private var day: SeasonSchedule.Day? { days.first { $0.id == selected } ?? days.first }
  static func weekday(_ ts: Int) -> String {
    let n = Calendar.current.component(.weekday, from: Date(timeIntervalSince1970: Double(ts)))
    return ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][max(0, min(6, n - 1))]
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      PGCSectionHeader(title: "更新日历", more: "完整日历") { SeasonCalendar() }
      if !days.isEmpty {
        ScrollViewReader { proxy in
          ScrollView(.horizontal) {
            HStack(spacing: 6) {
              ForEach(days) { d in
                let current = d.id == (selected ?? days.first?.id)
                Button {
                  TouchFeedback.light()
                  withAnimation(.snappy(duration: 0.25)) { selected = d.id }
                } label: {
                  VStack(spacing: 2) {
                    Text(d.is_today == 1 ? "今天" : Self.weekday(d.date_ts)).font(.caption.weight(.semibold))
                    Text(d.date).font(.caption2).monospacedDigit()
                  }
                  .foregroundStyle(current ? Color.white : Color.primary)
                  .frame(width: 52, height: 44)
                  .background(
                    current ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(uiColor: .secondarySystemBackground)),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }.buttonStyle(.plain).id(d.id)
              }
            }
          }
          .scrollIndicators(.hidden).scrollClipDisabled()
          .onAppear { if let s = selected { proxy.scrollTo(s, anchor: .center) } }
          .onChange(of: selected) { _, v in withAnimation(.snappy) { proxy.scrollTo(v, anchor: .center) } }
        }
      }
      if let failure {
        Text(failure).foregroundStyle(.secondary).font(.caption)
        Button("重试") { reload += 1 }
      }
      if let entries = day?.episodes, !entries.isEmpty {
        ScrollView(.horizontal) {
          LazyHStack(alignment: .top, spacing: 12) {
            ForEach(entries) { e in
              NavigationLink {
                if let id=e.playableEpisodeID {
                  EpisodeLink(id: id)
                } else {
                  SeasonView(
                    season: Season(
                      season_id: e.season_id, title: e.title, cover: e.cover,
                      index_show: e.pub_index))
                }
              } label: {
                VStack(alignment: .leading, spacing: 4) {
                  Rectangle().fill(.quaternary).aspectRatio(3 / 4, contentMode: .fit).overlay {
                    SiteThumbnail(url: httpsURL(e.cover)) {
                      $0.resizable().scaledToFill()
                    } placeholder: {
                      Color.clear
                    }
                  }
                  .overlay(alignment: .topTrailing) {
                    if e.follow == 1 {
                      Image(systemName: "bookmark.fill").font(.caption2).foregroundStyle(.white)
                        .padding(5).background(Color.accentColor, in: Circle()).padding(5)
                        .accessibilityLabel("已追番")
                    }
                  }
                  .clipped().clipShape(RoundedRectangle(cornerRadius: NativeGlass.thumbRadius, style: .continuous))
                  Text(e.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    .multilineTextAlignment(.leading).foregroundStyle(.primary)
                  Text(
                    [e.pub_time, e.delay == 1 ? (e.delay_reason ?? "延期") : e.pub_index].compactMap {
                      $0
                    }.joined(separator: " · ")
                  ).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }.frame(width: 108, alignment: .leading).contentShape(Rectangle())
              }.buttonStyle(.plain).seasonCover(e.cover)
            }
          }
        }.scrollIndicators(.hidden).scrollClipDisabled()
          .id(selected).transition(.opacity)
      } else if loaded && failure == nil {
        Text("当天暂无更新").font(.caption).foregroundStyle(.secondary)
      } else if !loaded {
        ProgressView()
      }
    }.task(id: reload) {
      failure = nil
      loaded = false
      async let anime = try? BiliAPI.shared.seasonUpdates(1, owner: owner)
      async let china = try? BiliAPI.shared.seasonUpdates(4, owner: owner)
      let (a, b) = await (anime, china)
      guard !Task.isCancelled else { return }
      days = SeasonSchedule.merge([a, b].compactMap { $0 })
      if selected == nil || !days.contains(where: { $0.id == selected }) {
        selected = days.first(where: { $0.is_today == 1 })?.id ?? days.first?.id
      }
      if a == nil && b == nil { failure = "未能载入更新日历" }
      loaded = true
    }
  }
}

private struct SeasonCover: ViewModifier {
  let raw: String
  @State private var show = false
  func body(content: Content) -> some View {
    content.contextMenu {
      if let u = httpsURL(raw) {
        Button("查看封面", systemImage: "photo") { show = true }
        Button("复制封面地址", systemImage: "doc.on.doc") { UIPasteboard.general.url = u }
      }
    }
    .piliSheet(isPresented: $show) {
      if let u = httpsURL(raw) {
        PiliNavigationStack { NativeGallery([.init(u)]).toolbar { Button("完成") { show = false } } }
      }
    }
  }
}
extension View { func seasonCover(_ raw: String) -> some View { modifier(SeasonCover(raw: raw)) } }
