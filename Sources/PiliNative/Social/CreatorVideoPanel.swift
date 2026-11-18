import SwiftUI

private struct CreatorCursorPage: Decodable {
  struct Entry: Decodable, Identifiable {
    struct Part: Decodable { let id: ServiceID? }
    let resource: ServiceID?, pages: [Part]?, bvid: String?, title: String?, cover: String?, duration: Int?, index: Int?
    enum CodingKeys: String, CodingKey { case resource = "id", bvid = "bv_id", pages, title, cover, duration, index }
    var aid: Int64? { resource?.number ?? bvid.flatMap(ArchiveNumber.av) }
    var id: String { bvid ?? aid.flatMap(ArchiveNumber.bv) ?? "" }
    var firstPart: Int64? { pages?.first?.id?.number.flatMap { $0 > 0 ? $0 : nil } }
  }
  let media_list: [Entry]?, total_count: Int?, has_more: Bool?
}

struct CreatorVideoPanel: View {
  let mid: Int64, name: String, current: String
  let choose: (Video, Int64?) -> Void
  @EnvironmentObject private var accounts: AccountContext
  @State private var order = "pubdate"
  @State private var rows: [CreatorCursorPage.Entry] = []
  @State private var previous = false
  @State private var next = false
  @State private var count: Int?
  @State private var busy = false
  @State private var issue: String?
  @State private var ticket = UUID()
  @State private var contentScope: String?
  @State private var loadedScope: String?
  @State private var failed: Direction = .initial
  private enum Direction { case initial, older, newer }
  private var scope: String { "\(mid):\(current):\(order):\(accounts.state.active ?? "")" }
  var body: some View {
    List {
      CreatorPanelIdentity(mid: mid, fallbackName: name)
      CreatorSpaceMetrics(mid: mid, fallback: nil)
      Section {
        if previous { Button("载入前面的投稿") { Task { await load(.newer) } }.disabled(busy) }
        ForEach(rows) { row in
          Button {
            choose(.preview(id: row.id, title: row.title ?? name, cover: row.cover ?? "", author: name, duration: row.duration),
              row.firstPart)
          } label: {
            MediaRow(cover: row.cover.flatMap(httpsURL), title: row.title ?? row.id,
              duration: row.duration.map { clockText(Double($0)) }, thumbWidth: 120) {
              if row.id == current {
                Image(systemName: "waveform").foregroundStyle(.tint).accessibilityLabel("正在播放")
              }
            }
          }
        }
        if busy { ProgressView() }
        else if let issue { Text(issue); Button("重试") { Task { await load(failed) } } }
        else if next { Button("载入更多投稿") { Task { await load(.older) } } }
        else if rows.isEmpty { Text("暂无投稿") }
      } header: {
        // The original's list header: the count on the left, the order as a quiet toggle on the right.
        HStack {
          Text(count.map { "投稿 · \($0)" } ?? "投稿")
          Spacer()
          Button {
            TouchFeedback.light()
            order = order == "click" ? "pubdate" : "click"
          } label: {
            Label(order == "click" ? "最多播放" : "最新发布", systemImage: "arrow.up.arrow.down").font(.footnote)
          }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
      }
    }.listStyle(.plain).navigationTitle(name)
      .task(id: scope) { if loadedScope != scope { await load(.initial) } }
      .refreshable { guard !busy else { return }; await load(previous ? .newer : .initial) }
  }
  @MainActor private func load(_ direction: Direction) async {
    guard direction == .initial || !busy else { return }
    let token = UUID(), opened = scope, actor = accounts.state.active
    ticket = token; busy = true; issue = nil; failed = direction
    if contentScope != opened {
      loadedScope = nil; rows = []; next = false; previous = false; count = nil
    }
    contentScope = opened
    defer { if ticket == token { busy = false } }
    do {
      var fields = ["type":"1", "biz_id":String(mid), "ps":"20", "otype":"2", "mobi_app":"web",
        "sort_field":order == "click" ? "2" : "1", "tid":"0", "desc":"true",
        "direction":direction == .newer ? "true" : "false", "with_current":direction == .initial ? "true" : "false"]
      let cursor: Int64?
      switch direction {
      case .initial: cursor = ArchiveNumber.av(current)
      case .newer: cursor = rows.first?.aid
      case .older: cursor = rows.last?.aid
      }
      if let cursor { fields["oid"] = String(cursor) }
      let data = try await BiliAPI.shared.read("/x/v2/medialist/resource/list", fields,
        expectedAccount: actor ?? "", as: CreatorCursorPage.self)
      try Task.checkCancellation()
      guard token == ticket, scope == opened else { return }
      var known = direction == .initial ? Set<String>() : Set(rows.map(\.id))
      let fresh = (data.media_list ?? []).filter { !$0.id.isEmpty && $0.aid != nil && known.insert($0.id).inserted }
      switch direction {
      case .initial:
        rows = fresh; previous = fresh.first.map { ($0.index ?? 1) > 0 } ?? false; next = !fresh.isEmpty && data.has_more == true
      case .newer: rows = fresh + rows; previous = !fresh.isEmpty && data.has_more == true
      case .older: rows += fresh; next = !fresh.isEmpty && data.has_more == true
      }
      if let n = data.total_count { count = n }
      loadedScope = opened
    } catch { if !Task.isCancelled && ticket == token && opened == scope { issue = error.localizedDescription } }
  }
}

struct CreatorSpaceMetrics: View {
  let mid: Int64, fallback: CreatorSpaceRecord.Person?
  @EnvironmentObject private var accounts: AccountContext
  private struct RelationStats: Decodable { let follower: Int64?, following: Int64? }
  private struct WorkStats: Decodable { let likes: Int64? }
  @State private var stats: RelationStats?
  @State private var work: WorkStats?
  var body: some View {
    // Counts as number-over-label columns, like the space header.
    HStack(spacing: 0) {
      NavigationLink { RelationsList(uid: String(mid), fans: true) } label: {
        column("粉丝", stats?.follower ?? fallback?.fans)
      }
      NavigationLink { RelationsList(uid: String(mid), fans: false) } label: {
        column("关注", stats?.following ?? fallback?.following)
      }
      column("获赞", work?.likes ?? fallback?.likes)
    }
    .buttonStyle(.plain)
    .task(id: "\(mid):\(accounts.state.active ?? "")") {
      let uid = accounts.state.active
      stats = nil; work = nil
      let api = BiliAPI.shared
      async let workResult = loadWork(uid)
      let r = try? await api.read("/x/relation/stat", ["vmid":String(mid)], expectedAccount: uid ?? "", as: RelationStats.self)
      guard !Task.isCancelled, uid == accounts.state.active else { return }
      stats = r
      let w = await workResult
      if !Task.isCancelled && uid == accounts.state.active { work = w }
    }
  }
  private func column(_ title: String, _ value: Int64?) -> some View {
    VStack(spacing: 2) {
      Text(value.map { $0.formatted(.number.notation(.compactName)) } ?? "-")
        .font(.headline.monospacedDigit()).foregroundStyle(.primary)
      Text(title).font(.caption).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity).contentShape(Rectangle())
  }
  private func loadWork(_ uid: String?) async -> WorkStats? {
    guard let uid else { return nil }
    return try? await BiliAPI.shared.read("/x/space/upstat", ["mid": String(mid)],
      expectedAccount: uid, as: WorkStats.self)
  }
}
