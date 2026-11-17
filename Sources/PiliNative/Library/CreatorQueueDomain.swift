import Foundation

enum CreatorArchiveSource: Hashable {
  case uploads(Int64)
  case season(Int64, Int64)
  case series(Int64, Int64)
  var creator: Int64 {
    switch self {
    case .uploads(let m), .season(let m, _), .series(let m, _): return m
    }
  }
  var business: Int64 {
    switch self {
    case .uploads(let m): return m
    case .season(_, let i), .series(_, let i): return i
    }
  }
  var uploads: Bool {
    if case .uploads = self { return true }
    return false
  }
  var key: String {
    switch self {
    case .uploads: return "u:\(creator)"
    case .season: return "c:\(creator):\(business)"
    case .series: return "s:\(creator):\(business)"
    }
  }
  var appPath: String {
    switch self {
    case .uploads: return "/x/v2/space/archive/cursor"
    case .season: return "/x/v2/space/season/videos"
    case .series: return "/x/v2/space/series"
    }
  }
  func descending(_ reverse: Bool) -> Bool {
    switch self {
    case .season: return reverse
    case .series: return !reverse
    case .uploads: return true
    }
  }
}
struct CreatorQueueOwners: Hashable {
  let main: String, recommend: String, history: String, video: String
  var key: [String] { [main, recommend, history, video] }
}
struct CreatorQueueHint: Equatable {
  let type: Int?, resume: Int64?, desc: Bool?, sort: Int?, owner: String?
  init?(source: CreatorArchiveSource, text: String?, uri: String?, owner: String? = nil) {
    self.owner = owner
    guard let uri, uri.utf8.count < 8192, let c = URLComponents(string: uri),
      let fields = c.queryItems
    else { return nil }
    func field(_ n: String) -> String? {
      let m = fields.filter { $0.name == n }
      return m.count == 1 ? m[0].value : nil
    }
    if let biz = field("biz_id"), Int64(biz) != source.business { return nil }
    let raw = field("page_type").flatMap(Int.init)
    // Values are returned by the space service for the selected collection or series. Never
    // dereference the button's URL or use its authority/account; only consume numeric parameters.
    if source.uploads {
      type = 1
    } else if let raw, raw > 0, raw <= 255 {
      type = raw
    } else {
      return nil
    }
    resume = text == "继续播放" ? field("oid").flatMap(Int64.init).flatMap { $0 > 0 ? $0 : nil } : nil
    desc = field("desc").flatMap {
      $0 == "1" || $0 == "true" ? true : $0 == "0" || $0 == "false" ? false : nil
    }
    sort = field("sort_field").flatMap(Int.init).flatMap { (1...2).contains($0) ? $0 : nil }
  }
}
struct CreatorArchiveScope: Hashable {
  let source: CreatorArchiveSource, title: String, order: String, reverse: Bool, tid: Int,
    special: String?, term: String, owners: CreatorQueueOwners
  var storageKey: String {
    // Length prefixes avoid accidental collisions with user-entered search text.
    ([source.key, order, String(reverse), String(tid), special ?? "", term] + owners.key).map {
      "\($0.utf8.count):\($0)"
    }.joined()
  }
  var filtered: Bool { tid != 0 || !(special ?? "").isEmpty || !term.isEmpty || order == "stow" }
  var sortField: Int { order == "click" ? 2 : 1 }
  func mayResume(_ h: CreatorQueueHint?) -> Bool {
    !filtered && !owners.history.isEmpty && (h?.owner ?? owners.main) == owners.history
      && h?.resume != nil
  }
  func listType(_ hint: CreatorQueueHint?) -> Int? {
    filtered ? nil : source.uploads ? 1 : hint?.type
  }
  // The archive controller supplies sortField for UP uploads (or when the service resumes a
  // list with sort_field). Its history POST sends upper_mid=queue business ID, not video aid.
  func history(aid: Int64, descending: Bool, canReport: Bool) -> [String: String]? {
    guard canReport, !filtered, aid > 0, source.business > 0, !owners.history.isEmpty else {
      return nil
    }
    return [
      "upper_mid": String(source.business), "oid": String(aid), "desc": descending ? "1" : "0",
    ]
  }
}
enum MediaCursorScope {
  case creator(CreatorArchiveScope)
  case shared(Int64, CreatorQueueOwners)
  var business: Int64 {
    switch self {
    case .creator(let scope): scope.source.business
    case .shared(let id, _): id
    }
  }
  var owner: String {
    switch self {
    case .creator(let scope): scope.owners.main
    case .shared(_, let owners): owners.main
    }
  }
  var defaultDescending: Bool {
    switch self {
    case .creator(let scope): scope.source.descending(scope.reverse)
    case .shared: true
    }
  }
  static func request(
    business: Int64, type: Int, desc: Bool, sort: Int, anchor: Int64?, edgeType: Int, prior: Bool,
    include: Bool
  )
    -> [String: String]
  {
    var f = [
      "type": String(type), "biz_id": String(business), "ps": "20",
      "direction": String(prior), "desc": String(desc), "sort_field": String(sort), "tid": "0",
      "with_current": String(include), "mobi_app": "web",
    ]
    if let anchor {
      f["oid"] = String(anchor)
      if !include { f["otype"] = String(edgeType) }
    }
    return f
  }
}
struct CreatorCursorMedia: Decodable {
  struct Part: Decodable { let id: ServiceID? }
  struct Author: Decodable { let name: String? }
  struct Counts: Decodable { let play: Int?, danmaku: Int? }
  let id: ServiceID?, aid: ServiceID?, ep_id: ServiceID?, bv_id: String?, bvid: String?,
    title: String?,
    cover: String?, duration: Int?, pages: [Part]?, upper: Author?, index: Int?, type: Int?,
    attr: Int?
  var cnt_info: Counts? = nil
  var pubtime: Int64? = nil
  // The cursor ID and type identify the service row. A 24 row does not turn its
  // numeric cursor into an archive; only an explicit BV or ep_id identifies its player.
  var rowType: Int { type ?? 2 }
  var genuineBV: String? {
    if let bv = bv_id ?? bvid, let aid = ArchiveNumber.av(bv) { return ArchiveNumber.bv(aid) }
    return rowType == 2 ? archive.flatMap(ArchiveNumber.bv) : nil
  }
  var sharedEpisode: Int64? { rowType == 24 ? ep_id?.number.flatMap { $0 > 0 ? $0 : nil } : nil }
  var rowID: String? { genuineBV ?? sharedEpisode.map { "ep:" + String($0) } }
  var displayID: String { rowID ?? "resource:\(rowType):\(archive ?? 0)" }
  var sharedSelectable: Bool {
    [2, 24].contains(rowType) && attr != 1 && attr != 9 && rowID != nil
  }
  var sharedPlayable: Bool {
    guard sharedSelectable else { return false }
    return sharedEpisode != nil || pages?.contains(where: { ($0.id?.number ?? 0) > 0 }) == true
  }
  var archive: Int64? { id?.number ?? aid?.number }
  var playable: Bool {
    (type == nil || type == 2) && pages?.contains(where: { ($0.id?.number ?? 0) > 0 }) == true
  }
}
struct CreatorCursorReply: Decodable {
  let media_list: [CreatorCursorMedia]?, has_more: Bool?, total_count: Int?
}
