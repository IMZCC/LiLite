import Foundation
import PiliWire
import SwiftUI

struct SpaceArchiveHit: Identifiable {
  let video: Video, target: SharedLink?, date: String, course: Bool
  var id: String { video.bvid }
  init?(_ row: PiliBilibiliAppInterfacesV1_Arc) {
    let arc = row.archive
    guard row.hasArchive, arc.aid > 0, let bv = ArchiveNumber.bv(arc.aid) else { return nil }
    let title = arc.title.replacingOccurrences(of: #"</?em(?: [^>]*)?>"#, with: "", options: [.regularExpression, .caseInsensitive])
    var v = Video(bvid: bv, title: title, pic: arc.pic, owner: .init(mid: arc.author.mid, name: arc.author.name),
      stat: .init(view: Int(arc.stat.view), danmaku: Int(arc.stat.danmaku)), duration: Int(exactly: arc.duration),
      desc: nil, cid: arc.firstCid > 0 ? arc.firstCid : nil, pages: nil)
    v.aid = arc.aid
    v.pubdate = arc.pubdate
    video = v
    course = row.isPugv
    date = row.publishTimeText
    target = SpaceArchiveTarget.resolve(bvid: bv, cid: arc.firstCid, course: row.isPugv, uri: row.uri, redirect: arc.redirectURL)
  }
}
private struct CreatorSearchArchiveCard: View {
  let hit: SpaceArchiveHit
  var body: some View {
    Group {
      if let target = hit.target { LazyLink { LinkDestination(item: target) } label: { label } }
      else { label.foregroundStyle(.secondary) }
    }.archiveCover(hit.video)
  }
  private var label: some View {
    VStack(alignment: .leading, spacing: 4) {
      SiteThumbnail(url: hit.video.cover) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.12) }
        .aspectRatio(16 / 9, contentMode: .fit).clipped()
        .overlay(alignment: .topLeading) { if hit.course { Text("课堂").font(.caption2).padding(3).background(.thinMaterial, in: Capsule()) } }
      Text(hit.video.title).lineLimit(2)
      HStack { if let count = hit.video.stat?.view { Label(String(count), systemImage: "play") }; if let count = hit.video.stat?.danmaku { Label(String(count), systemImage: "text.bubble") } }.font(.caption2)
      if !hit.date.isEmpty { Text(hit.date).font(.caption2) }
      else if let date = hit.video.pubdate, date > 0 { Text(Date(timeIntervalSince1970: Double(date)), style: .date).font(.caption2) }
    }
  }
}
struct CreatorSearch: View {
  let mid: Int64
  @EnvironmentObject private var accounts: AccountContext
  @State private var text = ""
  @State private var term = ""
  @State private var epoch = UUID()
  @State private var archive = true
  @State private var arcCount: Int?
  @State private var dynCount: Int?
  @State private var arcTop = 0
  @State private var dynTop = 0
  var body: some View {
    VStack {
      if term.isEmpty {
        ContentUnavailableView("搜索这位 UP 主的投稿和动态", systemImage: "magnifyingglass")
      } else {
        HStack {
          tab("投稿", number: arcCount, isArchive: true)
          tab("动态", number: dynCount, isArchive: false)
        }.padding(.horizontal)
        ZStack {
          results(true).opacity(archive ? 1 : 0).allowsHitTesting(archive).accessibilityHidden(!archive)
          results(false).opacity(archive ? 0 : 1).allowsHitTesting(!archive).accessibilityHidden(archive)
        }.id(epoch)
      }
    }.navigationTitle("空间搜索").searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "输入关键词")
      .onSubmit(of: .search) { restart(text) }
      .onChange(of: text) { _, value in if value.isEmpty { restart("") } }
      .onChange(of: accounts.state.active) { _, _ in restart(term) }
      .onChange(of: accounts.state.owner(.role(.recommend))) { _, _ in restart(term) }
  }
  private func tab(_ name: String, number: Int?, isArchive: Bool) -> some View {
    Button(name + (number.map { " \($0)" } ?? "")) {
      if isArchive == archive { if archive { arcTop &+= 1 } else { dynTop &+= 1 } }
      else { archive = isArchive }
    }.buttonStyle(.bordered).tint(isArchive == archive ? .accentColor : .secondary)
      .accessibilityAddTraits(isArchive == archive ? .isSelected : [])
  }
  private func restart(_ value: String) {
    term = value.trimmingCharacters(in: .whitespacesAndNewlines)
    epoch = UUID(); arcCount = nil; dynCount = nil
  }
  @ViewBuilder private func results(_ video: Bool) -> some View {
    let owner = accounts.state.active, keyword = term, stamp = epoch
    if video {
      PageList(empty: "没有找到投稿", grid: true, autoMore: true, active: archive, scrollToTopRequest: arcTop, prefetchFirstPage: true) { c in
        let page = Int(c ?? "1") ?? 1
        let response = try await SpaceSearchGateway.page(mid: mid, term: keyword, number: page) { data in
          try await BiliAPI.shared.mobileCall(SpaceSearchGateway.path, data, uid: owner, needsToken: false, readOnly: true)
        }
        try Task.checkCancellation()
        guard owner == accounts.state.active && stamp == epoch else { throw CancellationError() }
        arcCount = Int(exactly: max(0,response.total))
        return Page(items: response.archives.compactMap(SpaceArchiveHit.init),
          next: !response.archives.isEmpty && Int64(page * 20) < response.total ? String(page + 1) : nil)
      } row: { hit in CreatorSearchArchiveCard(hit: hit) }
    } else {
      let reader = accounts.state.owner(.role(.recommend))
      PageList(empty: "没有找到动态", dynamicCards: true, active: !archive, scrollToTopRequest: dynTop, prefetchFirstPage: true) { c in
        let parts = c?.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let page = parts?.first.flatMap { Int($0) } ?? 1
        let offset = parts?.last.map(String.init) ?? ""
        let data = try await BiliAPI.shared.dynamicData("/x/polymer/web-dynamic/v1/feed/space/search",
          ["host_mid": String(mid), "page": String(page), "offset": offset, "keyword": keyword, "features": "itemOpusStyle", "web_location": "333.1387"], expectedAccount: reader ?? "")
        try Task.checkCancellation()
        guard reader == accounts.state.owner(.role(.recommend)) && stamp == epoch else { throw CancellationError() }
        let filtering = Task.detached(priority: .userInitiated) {
          let filter = try MomentListFilter.current()
          let rows = data["items"] as? [[String: Any]] ?? []
          let items = rows.compactMap { DynamicEntry($0["dynamic_card_item"] as? [String: Any] ?? $0) }
            .filter { !Task.isCancelled && filter.accepts($0) }
          let next = data["offset"] as? String
          return Page(items: items, next: !rows.isEmpty && data["has_more"] as? Bool == true && next != offset ? next.map { String(page + 1) + ":" + $0 } : nil)
        }
        let result = try await withTaskCancellationHandler { try await filtering.value } onCancel: { filtering.cancel() }
        try Task.checkCancellation()
        guard reader == accounts.state.owner(.role(.recommend)) && stamp == epoch else { throw CancellationError() }
        dynCount = data["total"] as? Int ?? 0
        return result
      } row: { entry in DynamicCard(entry: entry) }
      .momentNavigation()
    }
  }
}
