import Foundation

/// Preview rows use service identities, not thumbnails or localized titles, as navigation targets.
struct ProfileShelfItem: Identifiable {
  enum Target: Hashable {
    case link(SharedLink)
    case folder(Int64)
    case season(Int64)
    case courseHistory(Int64, Bool, Int64?, Double?)
    case unavailable(String)
  }
  let id: String, title: String, caption: String?, cover: URL?, target: Target
  let progress: Double?
  init(
    id: String, title: String, caption: String?, cover: URL?, target: Target,
    progress: Double? = nil
  ) {
    self.id = id
    self.title = title
    self.caption = caption
    self.cover = cover
    self.target = target
    self.progress = progress
  }
}
struct MineHistoryPage: Decodable {
  struct Cursor: Decodable { let max: Int64?, view_at: Int64? }
  struct Tab: Decodable, Identifiable {
    let type: String, name: String
    var id: String { type }
  }
  struct Row: Decodable {
    struct Item: Decodable {
      let oid: Int64?, epid: Int64?, bvid: String?, page: Int?, cid: Int64?, business: String?
    }
    let history: Item?, title: String?, cover: String?, covers: [String]?, author_name: String?,
      uri: String?, progress: Int?, duration: Int?, live_status: Int?, kid: Int64?, badge: String?,
      show_title: String?, author_mid: Int64?, tag_name: String?, view_at: Int64?, is_fav: Int?
    var deleteKey: String? {
      guard let kind = history?.business, !kind.isEmpty,
        kind.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }), let kid, kid > 0
      else { return nil }
      return kind + "_" + String(kid)
    }
    var laterBVID: String? {
      guard history?.business == "archive", badge != "番剧", tag_name?.contains("动画") != true,
        let bvid = history?.bvid, case .video? = SharedLink.parse(bvid)
      else { return nil }
      return bvid
    }
    var entry: ProfileShelfItem? {
      guard let h = history, let kind = h.business else { return nil }
      let n = h.oid.flatMap { $0 > 0 ? $0 : nil }
      let t: SharedLink?
      switch kind {
      case "article-list": t = h.cid.flatMap { $0 > 0 ? .article($0) : nil }
      case "article": t = n.map(SharedLink.article)
      case "live": t = live_status == 1 ? n.map(SharedLink.room) : nil
      case "pgc": t = h.epid.flatMap { $0 > 0 ? .episode($0) : nil }
      case "cheese": t = uri.flatMap(SharedLink.parse)
      case "archive":
        if let bv = h.bvid, case .video? = SharedLink.parse(bv) {
          t = .video(bv, h.page)
        } else {
          t = n.map { .archive($0, h.page) }
        }
      default: t = uri.flatMap(SharedLink.parse)
      }
      let key = "\(kind):\(kid ?? n ?? h.epid ?? 0)"
      guard !key.hasSuffix(":0") else { return nil }
      var dest = t
      if let t, let seconds = progress, seconds >= -1 {
        switch t {
        case .video, .archive, .episode: dest = .positioned(t, Double(max(0, seconds)))
        default: break
        }
      }
      let played: Double? =
        (duration ?? 0) > 0
        ? progress.map { $0 < 0 ? 1 : min(1, Double($0) / Double(duration!)) } : nil
      let note =
        (kind == "live" && live_status != 1)
        ? "未开播" : (show_title?.isEmpty == false ? show_title : author_name ?? badge)
      let target: ProfileShelfItem.Target
      if case .course(let id, let ep) = t {
        target = .courseHistory(id, ep, n, progress.flatMap { $0 >= -1 ? Double(max(0, $0)) : nil })
      } else {
        target = dest.map(ProfileShelfItem.Target.link) ?? .unavailable(key)
      }
      return .init(
        id: key, title: title ?? "观看记录", caption: note,
        cover: (cover ?? covers?.first).flatMap(httpsURL),
        target: target, progress: played)
    }
  }
  let list: [Row]?, cursor: Cursor?, tab: [Tab]?
}
