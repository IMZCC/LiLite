import Foundation

extension CreatorQueueOwners {
  init(_ state: AccountJar.State) {
    self.init(
      main: state.owner(.role(.main)) ?? "", recommend: state.owner(.role(.recommend)) ?? "",
      history: state.owner(.role(.heartbeat)) ?? "", video: state.owner(.role(.video)) ?? "")
  }
}
struct CreatorArchiveTag: Decodable, Identifiable {
  let tid: Int?, name: String?, count: Int?, special_type: String?
  var id: String { "\(tid ?? 0):\(special_type ?? "")" }
}
struct CreatorArchivePage {
  let videos: [Video], tags: [CreatorArchiveTag], total: Int?, more: Bool
  var hint: CreatorQueueHint? = nil
}
enum CreatorArchiveCatalog {
  struct Row: Decodable {
    let bvid: String?, aid: Int64?, title: String?, pic: String?, author: String?, duration: Int?,
      length: String?
    var play: Int? = nil, video_review: Int? = nil, created: Int64? = nil
    /// Collections and series report counts under `stat` and the date as `pubdate`.
    struct Stat: Decodable {
      let view: Int?, danmaku: Int?
      enum K: String, CodingKey { case view, danmaku }
      init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        view = try? c.decode(Int.self, forKey: .view)
        danmaku = try? c.decode(Int.self, forKey: .danmaku)
      }
    }
    var stat: Stat? = nil, pubdate: Int64? = nil
    var video: Video? {
      guard
        let b = bvid.flatMap({ ArchiveNumber.av($0) != nil ? $0 : nil })
          ?? aid.flatMap(ArchiveNumber.bv)
      else { return nil }
      let time =
        duration
        ?? length.flatMap { value -> Int? in
          let fields = value.split(separator: ":", omittingEmptySubsequences: false)
          guard (1...3).contains(fields.count),
            fields.allSatisfy({
              !$0.isEmpty && $0.count <= 3 && $0.utf8.allSatisfy { (48...57).contains($0) }
            })
          else { return nil }
          let parts = fields.compactMap { Int($0) }
          guard parts.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
          return parts.reduce(0) { $0 * 60 + $1 }
        }
      return .preview(
        id: b, title: title ?? b, cover: pic ?? "", author: author, duration: time,
        views: play ?? stat?.view, danmaku: video_review ?? stat?.danmaku, published: created ?? pubdate)
    }
  }
  private struct Button: Decodable { let text: String?, uri: String? }
  private struct Meta: Decodable { let total: Int?, count: Int? }
  private struct Payload: Decodable {
    struct Collection: Decodable {
      let vlist: [Row]?, slist: [CreatorArchiveTag]?, tlist: [String: CreatorArchiveTag]?
      let episodic_button: Button?
      enum Keys: String, CodingKey { case vlist, slist, tlist, episodic_button }
      init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        episodic_button = try? c.decode(Button.self, forKey: .episodic_button)
        vlist = try c.decodeIfPresent([Row].self, forKey: .vlist)
        slist = try? c.decode([CreatorArchiveTag].self, forKey: .slist)
        tlist = try? c.decode([String: CreatorArchiveTag].self, forKey: .tlist)
      }
    }
    let list: Collection?, archives: [Row]?, page: Meta?, episodic_button: Button?
  }
  static func page(_ scope: CreatorArchiveScope, _ pn: Int, size: Int = 30) async throws
    -> CreatorArchivePage
  {
    guard pn > 0, pn <= 10_000_000, (1...30).contains(size) else { throw ServiceError("无效页码") }
    let api = BiliAPI.shared
    let r: Payload
    switch scope.source {
    case .uploads(let mid):
      var f = [
        "mid": String(mid), "pn": String(pn), "ps": String(size), "keyword": scope.term,
        "order": scope.order, "tid": String(scope.tid), "platform": "web",
        "web_location": "333.1387",
      ]
      f["special_type"] = scope.special
      r = try await api.read(
        "/x/space/wbi/arc/search", try await api.sign(f), expectedAccount: scope.owners.recommend,
        as: Payload.self)
    case .season(let mid, let sid):
      r = try await api.read(
        "/x/polymer/web-space/seasons_archives_list",
        [
          "mid": String(mid), "season_id": String(sid), "page_num": String(pn),
          "page_size": String(size),
          "sort_reverse": String(scope.reverse),
        ], expectedAccount: scope.owners.history, as: Payload.self)
    case .series(let mid, let sid):
      r = try await api.read(
        "/x/series/archives",
        [
          "mid": String(mid), "series_id": String(sid), "pn": String(pn), "ps": String(size),
          "sort": scope.reverse ? "asc" : "desc",
        ], expectedAccount: scope.owners.history, as: Payload.self)
    }
    try Task.checkCancellation()
    let all = r.list?.vlist ?? r.archives ?? []
    let total = r.page?.count ?? r.page?.total
    var seen = Set<String>()
    let tags =
      ((r.list?.slist ?? [])
      + Array((r.list?.tlist ?? [:]).values).sorted { ($0.tid ?? 0) < ($1.tid ?? 0) }).filter {
        seen.insert($0.id).inserted
      }
    let button = r.episodic_button ?? r.list?.episodic_button
    let hint = CreatorQueueHint(
      source: scope.source, text: button?.text, uri: button?.uri,
      owner: scope.source.uploads ? scope.owners.recommend : scope.owners.history)
    return .init(
      videos: all.compactMap(\.video), tags: tags, total: total,
      more: !all.isEmpty && (total.map { pn * size < $0 } ?? (all.count == size)), hint: hint)
  }
  static func hint(_ s: CreatorArchiveScope) async throws -> CreatorQueueHint? {
    guard !s.filtered else { return nil }
    struct Data: Decodable {
      struct Button: Decodable { let text: String?, uri: String? }
      let episodic_button: Button?
    }
    var fields = [
      "vmid": String(s.source.creator), "ps": "20", "qn": s.source.uploads ? "80" : "32",
      "c_locale": "zh_CN", "s_locale": "zh_CN", "channel": "master",
      "statistics": #"{"appId":1,"platform":3,"version":"8.43.0","abtest":""}"#,
      "build": "8430300", "version": "8.43.0", "mobi_app": "android", "platform": "android",
    ]
    switch s.source {
    case .uploads: fields["order"] = s.order
    case .season(_, let id):
      fields["season_id"] = String(id)
      fields["sort"] = s.reverse ? "asc" : "desc"
    case .series(_, let id):
      fields["series_id"] = String(id)
      fields["sort"] = s.reverse ? "asc" : "desc"
    }
    let host = "app.bilibili.com"
    let path = s.source.appPath
    let role = AccountRoutes.service(path, host: host)
    let owner: String
    switch role {
    case .role(.heartbeat): owner = s.owners.history
    case .role(.recommend): owner = s.owners.recommend
    case .role(.video): owner = s.owners.video
    default: owner = s.owners.main
    }
    let result = try await BiliAPI.shared.read(
      path, fields, host: host, expectedAccount: owner, as: Data.self)
    let b = result.episodic_button
    return CreatorQueueHint(source: s.source, text: b?.text, uri: b?.uri, owner: owner)
  }
}
extension CreatorCursorMedia {
  var key: Int64? { archive ?? (bv_id ?? bvid).flatMap(ArchiveNumber.av) }
  var video: Video? {
    guard playable, let k = key, k > 0, let b = ArchiveNumber.bv(k) else { return nil }
    return .preview(
      id: b, title: title ?? b, cover: cover ?? "", author: upper?.name, duration: duration,
      views: cnt_info?.play, danmaku: cnt_info?.danmaku, published: pubtime)
  }
}
