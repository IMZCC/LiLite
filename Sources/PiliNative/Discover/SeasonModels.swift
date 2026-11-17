import Foundation

struct Season: Decodable, Identifiable {
  let season_id: Int64, title: String, cover: String
  let index_show: String?
  var progress: String? = nil, new_ep: Update? = nil
  var badge: String?, order: String?, renewal_time: String?, is_finish: Int?
  var watchLabel: String? {
    [progress, new_ep?.index_show, index_show].compactMap { $0 }.first { !$0.isEmpty }
  }
  var cardLabels: [String] {
    var seen = Set<String>()
    return [badge, order, is_finish == 0 ? renewal_time : nil].compactMap { $0 }.filter {
      !$0.isEmpty && seen.insert($0).inserted
    }
  }
  struct Update: Decodable { let index_show: String? }
  var id: Int64 { season_id }
}
struct SeasonInfo: Decodable {
  var type: Int?
  var staff: String?, alias: String?, jp_title: String?, styles: [String]?,
    up_info: CourseCatalog.Teacher?, rights: Rights?, season_title: String?
  var usesHistoryOwner: Bool?, historyProgress: User.Progress?
  var activeProgress: User.Progress? {
    usesHistoryOwner == true ? historyProgress : user_status?.progress
  }
  struct Rights: Decodable { let can_watch: Int?, allow_review: Int?, allow_download: Int? }
  var viewingRestriction: String? {
    if user_status?.area_limit == 1 { return "所在地区暂不支持播放" }
    if rights?.can_watch == 0 { return "这部作品暂不可播放" }
    return nil
  }
  let media_id: Int64?, season_id: Int64?, title: String, evaluate: String?, cover: String?,
    subtitle: String?, actors: String?
  let episodes: [Episode]?, section: [Group]?, seasons: [Related]?, rating: Rating?, areas: [Area]?,
    publish: Publish?, new_ep: Latest?, stat: Stats?, user_status: User?
  struct Group: Decodable { let title: String?, episodes: [Episode]? }
  struct Related: Decodable { let season_id: Int64?, season_title: String?, cover: String? }
  struct Rating: Decodable { let score: Double?, count: Int? }
  struct Area: Decodable { let name: String? }
  struct Publish: Decodable { let pub_time_show: String? }
  struct Latest: Decodable { let desc: String?, title: String? }
  struct Stats: Decodable { let views: Int64?, danmakus: Int64? }
  struct User: Decodable {
    struct Progress: Decodable { let last_ep_id: Int64?, last_time: Double? }
    let favored: Int?, progress: Progress?
    var area_limit: Int?, payed: Int?, is_expired: Bool?
  }
  struct CatalogGroup: Identifiable {
    let id: Int, title: String, episodes: [Episode]
    var queue: [Episode] { episodes.filter(\.canRequestPlayback) }
  }
  var groups: [CatalogGroup] {
    var list = [CatalogGroup]()
    for (i, g) in ([Group(title: "正片", episodes: episodes)] + (section ?? [])).enumerated() {
      var seen = Set<Int64>()
      let rows = (g.episodes ?? []).filter { $0.id > 0 && seen.insert($0.id).inserted }.map { e in
        var row = e
        if let reason = viewingRestriction {
          row.barred = true
          row.accessReason = reason
        }
        if rights?.allow_download == 0 { row.forbidDownload = true }
        return row
      }
      if !rows.isEmpty {
        list.append(
          .init(
            id: i, title: g.title.flatMap { $0.isEmpty ? nil : $0 } ?? "分组 \(i)", episodes: rows))
      }
    }
    return list
  }
  func locate(_ id: Int64) -> (Episode, CatalogGroup)? {
    for group in groups {
      if let e = group.episodes.first(where: { $0.id == id }) { return (e, group) }
    }
    return nil
  }
  var resume: (Episode, CatalogGroup)? {
    resume(in: groups)
  }
  func resume(in catalog: [CatalogGroup]) -> (Episode, CatalogGroup)? {
    if let n = activeProgress?.last_ep_id {
      for group in catalog {
        if let episode = group.episodes.first(where: { $0.id == n }) {
          if episode.catalogPlayable { return (episode, group) }
          break
        }
      }
    }
    for g in catalog { if let e = g.episodes.first(where: \.catalogPlayable) { return (e, g) } }
    return nil
  }
  struct Episode: Decodable, Identifiable {
    var cover: String? = nil, share_copy: String? = nil, share_url: String? = nil
    var aid: Int64? = nil
    var id: Int64
    var cid: Int64
    let bvid: String, title: String, long_title: String?, badge: String?
    var page: Int?, courseFormat: Int?, studySeconds: Double?, studied: Bool?,
      previewMessage: String?, accessReason: String?, catalogIndex: Int?
    var isLiveCourse: Bool { courseFormat == 2 }
    var canResolveCID: Bool {
      !barred && !isLiveCourse && id > 0 && cid == 0 && ((aid ?? 0) > 0 || !bvid.isEmpty)
    }
    var catalogPlayable: Bool { canRequestPlayback || canResolveCID }
    var sourceID: Int64?, showTitle: String?, duration: Int?, play: Int?, preview = false,
      barred = false, forbidDownload = false
    var label: String {
      if let showTitle, !showTitle.isEmpty { return showTitle }
      let n = long_title ?? ""
      return n.isEmpty || title == n ? title : (title.isEmpty ? n : "\(title) · \(n)")
    }
    var canRequestPlayback: Bool { id > 0 && cid > 0 && !barred && !isLiveCourse }
    var playItem: Self? { canRequestPlayback ? self : nil }
    var allowCacheEntry: Bool { canRequestPlayback && !preview && !forbidDownload }
  }
}
extension SeasonInfo.Episode {
  enum Key: String, CodingKey {
    case id, ep_id, aid, cid, bvid, title, long_title, show_title, cover, share_copy, share_url,
      badge, duration, play, playable, rights, is_preview, allow_download, area_limit, can_watch,
      page, catalogue_index, play_way, watched, watchedHistory, episode_can_view, preview_toast
  }
  init(from decoder: Decoder) throws {
    let d = try decoder.container(keyedBy: Key.self)
    func n(_ k: Key) -> Int64? {
      (try? d.decode(Int64.self, forKey: k))
        ?? (try? d.decode(String.self, forKey: k)).flatMap(Int64.init)
    }
    func str(_ k: Key) -> String? { try? d.decode(String.self, forKey: k) }
    func flag(_ d: KeyedDecodingContainer<Key>?, _ k: Key) -> Bool? {
      if let v = try? d?.decode(Bool.self, forKey: k) { return v }
      if let v = try? d?.decode(Int.self, forKey: k) { return v != 0 }
      return nil
    }
    let rights = try? d.nestedContainer(keyedBy: Key.self, forKey: .rights)
    sourceID = n(.id)
    id = n(.ep_id).flatMap { $0 > 0 ? $0 : nil } ?? sourceID ?? 0
    cid = n(.cid) ?? 0
    aid = n(.aid)
    bvid = str(.bvid) ?? aid.flatMap(ArchiveNumber.bv) ?? ""
    title = str(.title) ?? ""
    long_title = str(.long_title)
    showTitle = str(.show_title)
    badge = str(.badge)
    cover = str(.cover)
    share_copy = str(.share_copy)
    share_url = str(.share_url)
    duration = n(.duration).flatMap(Int.init(exactly:))
    play = n(.play).flatMap(Int.init(exactly:))
    page = n(.page).flatMap(Int.init(exactly:))
    courseFormat = n(.play_way).flatMap(Int.init(exactly:))
    catalogIndex = n(.catalogue_index).flatMap(Int.init(exactly:))
    studied = flag(d, .watched)
    studySeconds = n(.watchedHistory).flatMap { $0 > 0 ? Double($0) : nil }
    previewMessage = str(.preview_toast).flatMap { $0.isEmpty ? nil : $0 }
    preview = flag(d, .is_preview) == true || flag(rights, .is_preview) == true
    barred =
      flag(d, .playable) == false || flag(rights, .can_watch) == false
      || n(.area_limit) == 1 || (try? rights?.decode(Int.self, forKey: .area_limit)) == 1
      || flag(d, .episode_can_view) == false
    if n(.area_limit) == 1 || (try? rights?.decode(Int.self, forKey: .area_limit)) == 1 {
      accessReason = "所在地区暂不支持播放"
    } else if barred {
      accessReason = "此集暂不可播放"
    }
    forbidDownload = flag(d, .allow_download) == false || flag(rights, .allow_download) == false
  }
}
struct CourseCatalog: Decodable {
  let season_id: Int64, title: String, subtitle: String?, cover: String?,
    user_status: SeasonInfo.User?
  let up_info: Teacher?, cooperators: [Teacher]?, brief: Brief?
  struct Teacher: Decodable {
    let mid: Int64?, avatar: String?, uname: String?, nick_name: String?, role: String?
  }
  var sections: [Section]?, ep_catalogue: [Chapter]?, episode_page: PageInfo?,
    release_info: String?, course_content: String?, stop_sell: Bool?, expiry_info_content: String?,
    paid_view: Bool?, drm_switch: Int?
  struct Section: Decodable {
    let id: Int64?, title: String?, section_type: Int?, episodes: [SeasonInfo.Episode]?
  }
  struct Chapter: Decodable {
    let index: Int?, title: String?, start_ep_index: Int?, end_ep_index: Int?
  }
  struct PageInfo: Decodable { let next: Bool?, num: Int?, size: Int?, total: Int? }
  struct Brief: Decodable {
    var title: String?, content: String?
    struct Picture: Decodable { let url: String? }
    let img: [Picture]?
  }
  var episodes: [SeasonInfo.Episode]?
  var lessons: [SeasonInfo.Episode] {
    groups.flatMap(\.episodes)
  }
  func preferred(episode: Int64?, aid: Int64?, useSaved: Bool = true) -> SeasonInfo.Episode? {
    if let aid { return lessons.first { $0.aid == aid } }
    if let episode { return lessons.first { $0.id == episode } }
    if useSaved, let n = user_status?.progress?.last_ep_id,
      let e = lessons.first(where: { $0.id == n })
    {
      return e
    }
    return lessons.first(where: \.canRequestPlayback) ?? lessons.first
  }
}

extension CourseCatalog {
  struct LessonGroup: Identifiable { let id: Int, title: String, episodes: [SeasonInfo.Episode] }
  /// V2 uses real sections, or a single default section divided by 1-based catalogue ranges.
  /// Only carry restrictions between matching lesson identities; never turn a refused V1 entry into a playable one.
  var groups: [LessonGroup] {
    var old = [Int64: SeasonInfo.Episode]()
    for e in episodes ?? [] { if let id = e.sourceID, id > 0 { old[id] = e } }
    func normalize(_ rows: [SeasonInfo.Episode], _ seen: inout Set<Int64>) -> [SeasonInfo.Episode] {
      rows.compactMap { raw in
        guard let id = raw.sourceID, id > 0, seen.insert(id).inserted else { return nil }
        var e = raw
        e.id = id
        if let legacy = old[id] {
          if legacy.barred {
            e.barred = true
            e.accessReason = legacy.accessReason
          }
          e.forbidDownload = e.forbidDownload || legacy.forbidDownload
          e.preview = e.preview || legacy.preview
        }
        if (drm_switch ?? 0) > 0 {
          e.barred = true
          e.forbidDownload = true
          e.accessReason = "此课程需使用官方播放器"
        }
        if user_status?.payed != 1,
          e.previewMessage?.contains("试看") == true
            || old[id]?.previewMessage?.contains("试看") == true
        {
          e.preview = true
        }
        return e
      }
    }
    let source = sections ?? []
    var seen = Set<Int64>()
    var out = [LessonGroup]()
    func append(_ title: String?, _ rows: [SeasonInfo.Episode]) {
      let items = normalize(rows, &seen)
      if !items.isEmpty {
        out.append(
          .init(
            id: out.count, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "课时", episodes: items))
      }
    }
    if source.count <= 1, (source.first?.section_type ?? 1) == 1, let catalog = ep_catalogue,
      !catalog.isEmpty
    {
      let rows = source.first?.episodes ?? episodes ?? []
      for c in catalog {
        guard let a = c.start_ep_index, let b = c.end_ep_index, a > 0, a <= b, a <= rows.count
        else { continue }
        append(c.title, Array(rows[(a - 1)..<min(b, rows.count)]))
      }
      append("其他课时", rows)
    } else {
      for section in source { append(section.title, section.episodes ?? []) }
    }
    if source.isEmpty { append(out.isEmpty ? "课时" : "其他课时", episodes ?? []) }
    return out
  }
  func continueSeconds(for item: SeasonInfo.Episode) -> Double? {
    if user_status?.progress?.last_ep_id == item.id, let n = user_status?.progress?.last_time,
      n.isFinite, n > 0
    {
      return n
    }
    return item.studySeconds
  }
  var partial: Bool { episode_page?.next == true && (episode_page?.total ?? 0) > lessons.count }
}


extension SeasonInfo.Episode{
  func historyFields(course:Bool,seasonID:Int64?,seasonType:Int?)->[String:String]{
    var fields=["cid":String(cid),"epid":String(id),"type":course ? "10":"4"]
    if course{if let aid,aid>0{fields["aid"]=String(aid)}}else if !bvid.isEmpty{fields["bvid"]=bvid}
    if let seasonID,seasonID>0{fields["sid"]=String(seasonID)}
    if let seasonType,seasonType>0{fields["sub_type"]=String(seasonType)}
    return fields
  }
}
