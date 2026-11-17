import SwiftUI

struct FavoriteMedia: Decodable, Identifiable {
  struct Upper: Decodable { let name: String?, mid: Int64? }
  struct Stats: Decodable { let play: Int64?, danmaku: Int64? }
  let number: Int64, type: Int
  let title: String?, cover: String?, intro: String?, bvid: String?, bv_id: String?, attr: Int?,
    duration: Int?, upper: Upper?, fav_time: Int64?, cnt_info: Stats?
  enum CodingKeys: String, CodingKey {
    case number = "id"
    case type, title, cover, intro, bvid, bv_id, attr, duration, upper, fav_time, cnt_info
  }
  var id: String { "\(number):\(type)" }
  var unavailable: Bool { attr == 1 || attr == 9 }
  var displayName: String { title ?? (unavailable ? "已失效的收藏" : "收藏内容") }
  var route: SharedLink? {
    guard number > 0 else { return nil }
    if unavailable { return upper?.mid.flatMap { $0 > 0 ? SharedLink.creator($0) : nil } }
    switch type {
    case 12: return .song(number)
    case 24: return .episode(number)
    default:
      if let bv = bvid ?? bv_id, case .video? = SharedLink.parse(bv) { return .video(bv, 1) }
      return type == 2 ? .archive(number, 1) : nil
    }
  }
}
enum FavoriteSort: String, CaseIterable {
  case mtime, view, pubtime
  var label: String {
    switch self {
    case .mtime: "最近收藏"
    case .view: "最多播放"
    case .pubtime: "最近投稿"
    }
  }
}
extension BiliAPI {
  func favoriteMedia(
    _ folder: Int64, page: Int, term: String, order: FavoriteSort = .mtime, user: String? = nil,
    across: Bool = false
  ) async throws -> Page<FavoriteMedia> {
    struct Result: Decodable { let medias: [FavoriteMedia]?, has_more: Bool? }
    let r = try await read(
      "/x/v3/fav/resource/list",
      [
        "media_id": String(folder), "pn": String(page), "ps": "20", "keyword": term,
        "order": order.rawValue, "type": across ? "1" : "0", "tid": "0", "platform": "web",
      ], expectedAccount: user, as: Result.self)
    let rows = r.medias ?? []
    return .init(items: rows, next: !rows.isEmpty && r.has_more == true ? String(page + 1) : nil)
  }
}
struct FavoriteMediaLink: View {
  let media: FavoriteMedia
  var body: some View {
    if let route = media.route {
      PlainRowLink {
        if case .song(let sid)=route{AudioCardEntry(id:sid,title:media.displayName,origin:.card(sid))}
        else{LinkDestination(item:route)}
      } label: {
        FavoriteMediaLabel(media: media)
      }
    } else {
      FavoriteMediaLabel(media: media)
    }
  }
}
struct FavoriteMediaLabel: View {
  let media: FavoriteMedia
  private func upperName(_ media: FavoriteMedia) -> String {
    if let upper = media.upper, upper.mid != nil, let name = upper.name { return "已失效 · " + name }
    return "已失效"
  }
  var body: some View {
    let stats = media.type == 24 ? nil : media.cnt_info
    let favoured = MediaStats.published(media.fav_time).map { $0 + "收藏" }
    return MediaRow(
      cover: media.cover.flatMap(httpsURL), title: media.displayName,
      badge: media.unavailable ? "已失效" : (media.type == 12 ? "音频" : media.type == 24 ? "影视" : nil),
      duration: media.duration.flatMap { $0 > 0 ? clockText(Double($0)) : nil },
      subtitle: media.unavailable ? upperName(media) : media.upper?.name,
      detail: stats.map { MediaStats.line(views: $0.play.map(Int.init), danmaku: $0.danmaku.map(Int.init), extra: [favoured]) } ?? favoured,
      dimmed: media.unavailable)
  }
}
enum CloudEntry: Identifiable {
  case sharedItem(CreatorCursorMedia)
  case video(Video)
  case favorite(FavoriteMedia)
  case later(LaterMedia)
  var id: String {
    switch self {
    case .sharedItem(let v): v.displayID
    case .video(let v): v.historyKey ?? v.id
    case .later(let l): l.id
    case .favorite(let f): f.id
    }
  }
  var title: String {
    switch self {
    case .sharedItem(let v):v.title ?? "视频"
    case .video(let v): v.title
    case .later(let l): l.name
    case .favorite(let f): f.displayName
    }
  }
  @ViewBuilder var link: some View {
    switch self {
    case .sharedItem: if let target=queueTarget {PlainRowLink{LinkDestination(item:target)} label: {label}}else{label}
    case .video(let v): VideoLink(video: v)
    case .favorite(let f): FavoriteMediaLink(media: f)
    case .later(let m):
      if let route = m.route {
        PlainRowLink {
          if case .video(let b, _) = route {
            DetailView(
              initial: .preview(id: b, title: m.name, cover: m.pic ?? "", author: m.owner?.name),
              libraryPoint: libraryPoint)
          } else {
            LinkDestination(item: route)
          }
        } label: {
          LaterLabel(media: m)
        }
      } else {
        LaterLabel(media: m)
      }
    }
  }
  /// The full row (duration, progress, counts) for every library source.
  @ViewBuilder var label: some View {
    switch self {
    case .later(let m): LaterLabel(media: m)
    case .favorite(let f): FavoriteMediaLabel(media: f)
    case .video(let v):
      MediaRow(
        cover: v.cover, title: v.title, duration: v.duration.map { clockText(Double($0)) },
        subtitle: v.owner?.name,
        detail: MediaStats.line(views: v.stat?.view, danmaku: v.stat?.danmaku))
    case .sharedItem(let r):
      MediaRow(
        cover: r.cover.flatMap(httpsURL), title: r.title ?? "视频",
        duration: r.duration.flatMap { $0 > 0 ? clockText(Double($0)) : nil },
        subtitle: r.upper?.name,
        detail: MediaStats.line(views: r.cnt_info?.play, danmaku: r.cnt_info?.danmaku),
        dimmed: !r.sharedSelectable)
    }
  }
}
struct LaterLabel: View {
  let media: LaterMedia
  var body: some View {
    let length = media.duration.flatMap { $0 > 0 ? Double($0) : nil }
    let watched: Double? = media.progress == -1 ? 1
      : media.progress.flatMap { p in length.map { p > 0 ? Double(p) / $0 : 0 } }
    MediaRow(
      cover: media.cover, title: media.name, badge: media.badge,
      duration: length.map { clockText($0) }, progress: watched,
      subtitle: [media.owner?.name, media.subtitle].compactMap { $0 }.filter { !$0.isEmpty }
        .joined(separator: " · "),
      detail: MediaStats.line(
        views: media.stat?.view, danmaku: media.stat?.danmaku, extra: [media.progressText]),
      dimmed: media.route == nil)
  }
}
extension Page {
  func transform<New>(_ f: (Item) -> New) -> Page<New> {
    Page<New>(items: items.map(f), next: next)
  }
}
