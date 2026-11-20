import SwiftUI

struct SeasonCalendar: View {
  @EnvironmentObject private var accounts: AccountContext
  @State private var type = 0
  private var owner: String { accounts.state.active ?? "" }
  var body: some View {
    VStack(spacing: 0) {
      PageList(empty: "暂无更新") { _ in
        let days: [SeasonSchedule.Day]
        if type == 0 {
          async let anime = try? BiliAPI.shared.seasonUpdates(1, owner: owner)
          async let domestic = try? BiliAPI.shared.seasonUpdates(4, owner: owner)
          let (a, b) = await (anime, domestic)
          try Task.checkCancellation()
          guard a != nil || b != nil else { throw ServiceError("未能载入更新日历") }
          days = SeasonSchedule.merge([a, b].compactMap { $0 })
        } else {
          days = try await BiliAPI.shared.seasonUpdates(type, owner: owner)
        }
        return Page(items: days, next: nil)
      } row: { d in
        Section(d.date + (d.is_today == 1 ? " · 今天" : "")) {
          if d.episodes?.isEmpty != false { Text("暂无更新").foregroundStyle(.secondary) }
          ForEach(d.episodes ?? []) { e in
            PlainRowLink {
              if let id=e.playableEpisodeID {
                EpisodeLink(id: id)
              } else {
                SeasonView(
                  season: .init(
                    season_id: e.season_id, title: e.title, cover: e.cover, index_show: e.pub_index)
                )
              }
            } label: {
              PosterRow(
                cover: httpsURL(e.cover), title: e.title,
                badge: e.follow == 1 ? "已追" : nil,
                lines: [e.pub_time.map { $0 + " 更新" } ?? ""],
                accent: e.delay == 1 ? e.delay_reason ?? "延期" : e.pub_index, width: 60)
            }.seasonCover(e.cover)
          }
        }
      }.id("\(type):\(owner)")
    }
    .piliSafeAreaBar(edge: .top, spacing: 0) {
      ChipBar(items: [0, 1, 4], selection: $type, title: { ["全部", "番剧", "", "", "国创"][$0] })
        .padding(.vertical, 6)
    }
    .navigationTitle("更新日历")
  }
}
struct FollowedSeasons: View {
  private let fixedType: Bool
  @EnvironmentObject private var accounts: AccountContext
  private var mine: Bool { accounts.state.active == uid }
  let uid: String
  struct ListResult: Decodable { let list: [Season]?, total: Int? }
  @State private var type: Int
  init(uid: String, initialType: Int = 1, fixedType: Bool = false) {
    self.fixedType = fixedType
    self.uid = uid
    _type = State(initialValue: initialType)
  }
  @State private var status = 2
  @State private var loaded = Set<Int64>()
  @State private var selected = Set<Int64>()
  @State private var selecting = false
  @State private var remove: Season?
  @State private var revision = 0
  @State private var busy = false
  @State private var issue: String?
  var body: some View {
    VStack(spacing: 0) {
      PageList(empty: "暂无作品") { cursor in
        let p = Int(cursor ?? "1") ?? 1
        var q = ["vmid": uid, "type": "\(type)", "pn": "\(p)", "ps": "15"]
        if status > 0 { q["follow_status"] = "\(status)" }
        let r = try await BiliAPI.shared.read(
          "/x/space/bangumi/follow/list", q, expectedAccount: accounts.state.active ?? "",
          as: ListResult.self)
        try Task.checkCancellation()
        if cursor == nil { loaded = [] }
        loaded.formUnion((r.list ?? []).map(\.id))
        return Page(items: r.list ?? [], next: p * 15 < (r.total ?? 0) ? "\(p+1)" : nil)
      } row: { s in
        Group {
          if selecting && mine {
            Button {
              if !selected.insert(s.id).inserted { selected.remove(s.id) }
            } label: {
              HStack(spacing: 12) {
                Image(systemName: selected.contains(s.id) ? "checkmark.circle.fill" : "circle")
                  .font(.system(size: 20))
                  .foregroundStyle(selected.contains(s.id) ? Color.accentColor : Color.secondary)
                  .contentTransition(.symbolEffect(.replace))
                FollowedSeasonRow(season: s, cinema: type == 2) { EmptyView() }
              }
            }.buttonStyle(.plain)
          } else {
            PlainRowLink {
              SeasonView(season: s)
            } label: {
              FollowedSeasonRow(season: s, cinema: type == 2) {
                if mine {
                  Menu { moveActions(s) } label: {
                    Image(systemName: "ellipsis").rotationEffect(.degrees(90))
                      .font(.system(size: 15, weight: .semibold)).foregroundStyle(FollowedSeasonRow<EmptyView>.grey)
                      .frame(width: 30, height: 30).contentShape(Rectangle())
                  }
                  .menuStyle(.button).buttonStyle(.plain)
                  .accessibilityLabel("更多")
                }
              }
            }
            .contextMenu {
              if mine {
                Button("选择") {
                  selected = [s.id]
                  selecting = true
                }
                moveActions(s)
              }
            }.swipeActions { if mine { Button("取消追番追剧", role: .destructive) { remove = s } } }
          }
        }
        // Rows from 16pt in, each drawing its own divider.
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 10))
        .listRowSeparator(.hidden)
      }.id("\(uid):\(accounts.state.active ?? ""):\(type):\(status):\(revision)")
    }
    .piliSafeAreaBar(edge: .top, spacing: 0) { header }
    .navigationTitle(fixedType ? (type == 1 ? "追番" : "追剧") : "追番追剧").disabled(busy)
      .onChange(of: type) { _, _ in reset() }.onChange(of: status) { _, _ in reset() }
      .onChange(of: accounts.state.active) { _, _ in reset() }
      .toolbar {
        if mine && selecting {
          Menu("已选 \(selected.count)") {
            Button("全选已加载作品") { selected = loaded }
            Button("取消全选") { selected = [] }
            ForEach(destinations, id: \.self) { dest in
              Button("移到" + statusText(dest)) { Task { await move(selected, to: dest) } }
                .disabled(selected.isEmpty)
            }
          }
        }
      }
      .confirmationDialog(
        "取消追番追剧？", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } }),
        presenting: remove
      ) { season in
        Button("取消追番追剧", role: .destructive) { Task { await move([season.id], to: 0) } }
      }
      .alert("追番追剧", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
        Button("好") {}
      } message: {
        Text(issue ?? "")
      }
  }
  @Namespace private var tabs
  /// Two levels, as in the official page: 追番 / 追剧 as the page's tabs, then the 想看 · 在看 ·
  /// 看过 filters as small chips with 管理 at their end, over a hairline.
  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !fixedType {
        HStack(spacing: 26) {
          ForEach([1, 2], id: \.self) { kind in
            let current = type == kind
            Button {
              guard !current else { return }
              TouchFeedback.light()
              withAnimation(.snappy(duration: 0.28)) { type = kind }
            } label: {
              VStack(spacing: 5) {
                // The semibold title's width reserved, so the weight change never shifts the tabs.
                Text(kind == 1 ? "追番" : "追剧").font(.system(size: 17, weight: .semibold)).hidden()
                  .overlay {
                    Text(kind == 1 ? "追番" : "追剧")
                      .font(.system(size: 17, weight: current ? .semibold : .regular))
                      .foregroundStyle(current ? Color.primary : Color.secondary)
                  }
                ZStack {
                  if current {
                    Capsule().fill(Color.accentColor).frame(width: 18, height: 3)
                      .matchedGeometryEffect(id: "underline", in: tabs)
                  }
                }.frame(height: 3)
              }.contentShape(Rectangle())
            }.buttonStyle(.plain)
          }
        }
      }
      HStack(spacing: 8) {
        ForEach([1, 2, 3], id: \.self) { value in
          let current = status == value
          Button {
            guard !current else { return }
            TouchFeedback.light()
            withAnimation(.snappy(duration: 0.25)) { status = value }
          } label: {
            Text(statusText(value))
              .font(.system(size: 13, weight: current ? .semibold : .regular))
              .foregroundStyle(current ? Color.accentColor : Color.secondary)
              .padding(.horizontal, 12).padding(.vertical, 5)
              .background(current ? Color.accentColor.opacity(0.12) : Color(uiColor: .tertiarySystemFill), in: Capsule())
          }.buttonStyle(.plain)
        }
        Spacer(minLength: 0)
        if mine {
          Button {
            TouchFeedback.light()
            withAnimation(.snappy(duration: 0.25)) {
              selecting.toggle()
              selected = []
            }
          } label: {
            Label(selecting ? "完成" : "管理", systemImage: selecting ? "checkmark" : "list.bullet")
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(selecting ? Color.accentColor : Color.secondary)
              .padding(.vertical, 5).contentShape(Rectangle())
          }.buttonStyle(.plain)
        }
      }
    }
    .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) { Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5) }
  }
  private var destinations: [Int] { [1, 2, 3].filter { $0 != status } }
  /// The official row's "⋮" sheet: move to another list, or stop following.
  @ViewBuilder private func moveActions(_ s: Season) -> some View {
    ForEach(destinations, id: \.self) { dest in
      Button("移到" + statusText(dest)) { Task { await move([s.id], to: dest) } }
    }
    Button("取消追番追剧", role: .destructive) { remove = s }
  }
  private func statusText(_ n: Int) -> String { ["", "想看", "在看", "看过"][n] }
  private func reset() {
    selected = []
    loaded = []
    selecting = false
    revision += 1
  }
  private func move(_ ids: Set<Int64>, to target: Int) async {
    guard mine, !busy, !ids.isEmpty, ids.isSubset(of: loaded), (0...3).contains(target),
      target != 0 || ids.count == 1
    else { return }
    busy = true
    defer { busy = false }
    var fields = ["season_id": ids.sorted().map(String.init).joined(separator: ",")]
    if target > 0 { fields["status"] = String(target) }
    do {
      try await BiliAPI.shared.submit(
        target == 0 ? "/pgc/web/follow/del" : "/pgc/web/follow/status/update", fields,
        expectedAccount: uid)
      reset()
    } catch { issue = error.localizedDescription }
  }
}
/// One followed show as the official 追番 / 追剧 list draws it (`bangumi_item_common_collection`):
/// a 78 × 104 poster 10pt down with its badge; beside it from 8pt down the title (14pt, two
/// lines), for 追剧 the styles and areas, the latest episode (pink while it is unwatched) and the
/// watch progress; the "⋮" in the bottom-right corner. Sized up for the iPhone (84 × 112 poster,
/// 16 / 13pt text) with the progress row on the poster's bottom line.
struct FollowedSeasonRow<Accessory: View>: View {
  let season: Season
  let cinema: Bool
  @ViewBuilder var accessory: () -> Accessory
  static var grey: Color { dynamic(0x9499A0, 0x757A81) }
  private static var ink: Color { dynamic(0x18191C, 0xE7E9EB) }
  private static var pink: Color { dynamic(0xFB7299, 0xD44E7D) }
  private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
    func color(_ n: UInt32) -> UIColor {
      UIColor(red: CGFloat(n >> 16 & 255) / 255, green: CGFloat(n >> 8 & 255) / 255, blue: CGFloat(n & 255) / 255, alpha: 1)
    }
    let l = color(light), d = color(dark)
    return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? d : l })
  }
  /// The poster, 3:4; the text column spans its height.
  private static var posterSize: CGSize { CGSize(width: 84, height: 112) }
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      poster
      // Title and episode state from the top, the watch progress and "⋮" on the poster's
      // bottom line, so the column is as tall as the poster instead of a block at its top.
      VStack(alignment: .leading, spacing: 0) {
        Text(season.title).font(.system(size: 16, weight: .medium)).foregroundStyle(Self.ink)
          .lineLimit(2).multilineTextAlignment(.leading).padding(.top, 1)
        if cinema, let meta { line(meta, Self.grey).padding(.top, 5) }
        if let update { line(update, unwatched ? Self.pink : Self.grey).padding(.top, 5) }
        Spacer(minLength: 6)
        HStack(spacing: 4) {
          line(season.progress.flatMap { $0.isEmpty ? nil : $0 } ?? "尚未观看", Self.grey)
          Spacer(minLength: 0)
          accessory()
        }
        .frame(minHeight: 30)
        .padding(.bottom, -6)
      }
      .frame(maxWidth: .infinity, minHeight: Self.posterSize.height, alignment: .topLeading)
    }
    .padding(.vertical, 12)
    // The row's own hairline (Ga2), as the official item draws it, instead of the list's
    // separator: SwiftUI hides that one beside a row it still counts as selected after a pop.
    .overlay(alignment: .bottom) { Rectangle().fill(Self.dynamic(0xE3E5E7, 0x2F3134)).frame(height: 0.5) }
    .contentShape(Rectangle())
  }
  private var poster: some View {
    Rectangle().fill(.quaternary).frame(width: Self.posterSize.width, height: Self.posterSize.height)
      .overlay { SiteThumbnail(url: httpsURL(season.cover)) { $0.resizable().scaledToFill() } placeholder: { Color.clear } }
      .overlay(alignment: .topTrailing) {
        if let badge = season.badge, !badge.isEmpty {
          Text(badge).font(.system(size: 10, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 4).padding(.vertical, 0.5)
            .background(badgeColor, in: RoundedRectangle(cornerRadius: 2, style: .continuous))
            .padding(.top, 4).padding(.trailing, 4)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
  private var badgeColor: Color {
    guard let raw = season.badge_info?.value?.bg_color else { return Self.pink }
    let hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
    guard hex.count == 6, let n = UInt32(hex, radix: 16) else { return Self.pink }
    return Color(red: Double(n >> 16) / 255, green: Double(n >> 8 & 255) / 255, blue: Double(n & 255) / 255)
  }
  private func line(_ text: String, _ color: Color) -> some View {
    Text(text).font(.system(size: 13)).foregroundStyle(color).lineLimit(1)
  }
  /// 追剧: the styles, then up to three areas, as the official row shows them.
  private var meta: String? {
    let styles = (season.styles?.value ?? []).filter { !$0.isEmpty }.joined(separator: "/")
    let areas = (season.areas?.value ?? []).compactMap(\.name).filter { !$0.isEmpty }.prefix(3).joined(separator: "、")
    let text = [styles, areas].filter { !$0.isEmpty }.joined(separator: " | ")
    return text.isEmpty ? nil : text
  }
  private var update: String? {
    [season.new_ep?.index_show, season.index_show].compactMap { $0 }.first { !$0.isEmpty }
  }
  /// The latest episode is past the one watched (or an airing show not yet started).
  private var unwatched: Bool {
    // Episode numbers only ("第12话", "全12集"): a film's release date or a watched time is not one.
    func number(_ text: String?, after marks: [String]) -> Int? {
      guard let text else { return nil }
      for mark in marks {
        guard let found = text.range(of: mark) else { continue }
        let digits = text[found.upperBound...].prefix { $0.isNumber }
        if let n = Int(digits) { return n }
      }
      return nil
    }
    guard let latest = number(season.new_ep?.index_show ?? season.index_show, after: ["第", "全"]) else { return false }
    guard let watched = number(season.progress, after: ["第"]) else {
      return season.is_finish == 0 && season.progress?.isEmpty != false
    }
    return latest > watched
  }
}
struct SeasonFollow: View {
  let id: Int64
  struct Status: Decodable { let follow: Int?, follow_status: Int? }
  @EnvironmentObject var accounts: AccountContext
  @State private var status: Status?
  @State private var issue: String?
  @State private var busy = false
  var body: some View {
    if let owner = accounts.state.active {
      Section {
        if let s = status {
          if s.follow == 1 {
            Picker(
              "观看状态",
              selection: Binding(
                get: { s.follow_status ?? 2 }, set: { v in Task { await set(v, owner: owner) } })
            ) {
              Text("想看").tag(1)
              Text("在看").tag(2)
              Text("看过").tag(3)
            }
            Button("取消追番追剧", role: .destructive) { Task { await set(0, owner: owner) } }
          } else {
            Button("追番追剧") { Task { await set(-1, owner: owner) } }
          }
        } else if issue == nil {
          PageLoading()
        }
        if let issue {
          PageFailure(message: issue) { Task { await load(owner) } }
        }
      }.disabled(busy).task(id: "\(id):\(owner)") {
        status = nil
        issue = nil
        await load(owner)
      }
    }
  }
  private func load(_ owner: String) async {
    do {
      let next = try await BiliAPI.shared.read(
        "/pgc/view/web/season/user/status", ["season_id": "\(id)"], expectedAccount: owner,
        as: Status.self)
      guard !Task.isCancelled, accounts.state.active == owner else { return }
      status = next
      issue = nil
    } catch {
      if !Task.isCancelled && accounts.state.active == owner { issue = error.localizedDescription }
    }
  }
  private func set(_ target: Int, owner: String) async {
    guard !busy, accounts.state.active == owner else { return }
    busy = true
    defer { busy = false }
    var f = ["season_id": "\(id)"]
    if target > 0 { f["status"] = "\(target)" }
    do {
      try await BiliAPI.shared.submit(
        "/pgc/web/follow/" + (target < 0 ? "add" : target == 0 ? "del" : "status/update"), f,
        expectedAccount: owner)
      await load(owner)
    } catch {
      if !Task.isCancelled && accounts.state.active == owner { issue = error.localizedDescription }
    }
  }
}
