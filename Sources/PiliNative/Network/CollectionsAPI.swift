import Foundation

struct Page<Item> {
  let items: [Item]
  let next: String?
  var reportedTotal:Int? = nil
}
struct Folder: Decodable, Identifiable {
  let id: Int64
  let title: String
  let media_count: Int?
  var fav_state: Int? = nil, attr: Int? = nil, cover: String? = nil, intro: String? = nil
  var isDefault: Bool { attr.map { ($0 & 2) == 0 } ?? false }
  var isPublic: Bool { attr.map { ($0 & 1) == 0 } ?? false }
}
struct AccountProfile: Decodable {
  let mid: Int64
  let uname: String
  let face: String?
  var vipStatus: Int? = nil, vipType: Int? = nil, is_senior_member: Int? = nil, money: Double? = nil
  var level_info: Level? = nil
  /// The avatar frame ("头像框"), from the nav endpoint.
  var pendant: Pendant? = nil
  struct Pendant: Decodable { let image: String?; let image_enhance: String? }
  var pendantURL: URL? {
    guard let p = pendant else { return nil }
    let raw = [p.image_enhance, p.image].compactMap { $0 }.first { !$0.isEmpty }
    return raw.flatMap(httpsURL)
  }
  struct Level: Decodable {
    let current_level: Int?, current_exp: Int?, next: Int?
    enum CodingKeys: String, CodingKey { case current_level, current_exp, next_exp }
    init(from d: Decoder) throws {
      let c = try d.container(keyedBy: CodingKeys.self)
      current_level = try c.decodeIfPresent(Int.self, forKey: .current_level)
      current_exp = try c.decodeIfPresent(Int.self, forKey: .current_exp)
      next = current_level == 6 ? current_exp : (try? c.decode(Int.self, forKey: .next_exp))
    }
  }
}
extension Video {
  static func preview(
    id: String, title: String, cover: String, author: String?, duration: Int? = nil,
    views: Int? = nil, danmaku: Int? = nil, published: Int64? = nil
  ) -> Video {
    var v = Video(
      bvid: id, title: title, pic: cover, owner: author.map { Owner(name: $0) },
      stat: views == nil && danmaku == nil ? nil : Stat(view: views, danmaku: danmaku),
      duration: duration, desc: nil, cid: nil, pages: nil)
    v.pubdate = published.flatMap { $0 > 0 ? $0 : nil }
    return v
  }
}
extension BiliAPI {
  func profile(expectedAccount: String? = nil) async throws -> AccountProfile {
    try await read(
      "/x/web-interface/nav", [:], expectedAccount: expectedAccount, as: AccountProfile.self)
  }
  func findVideos(_ term:String,order:String,duration:Int,page:Int,options:[String:String]=[:],owner:String?=nil)async throws->Page<Video>{
    var fields=options;fields["duration"]=String(duration);if order != "totalrank" && !order.isEmpty{fields["order"]=order}
    let p=try await searchPage(term,domain:.video,page:page,fields:fields,owner:owner)
    return Page(items:p.items.compactMap{if case .video(let v)=$0.content{return v};return nil},next:p.next,reportedTotal:p.reportedTotal)
  }
  func later(
    page: Int, keyword: String, viewed: Int = 0, ascending: Bool = false, uid: String? = nil
  ) async throws -> Page<LaterMedia> {
    struct Result: Decodable {
      let list: [LaterMedia]?
      let count: Int?
    }
    let q = try await sign([
      "pn": "\(page)", "ps": "20", "viewed": viewed == 2 ? "2" : "0", "key": keyword,
      "asc": ascending ? "true" : "false",
      "need_split": "true", "web_location": "333.881",
    ])
    let r = try await read("/x/v2/history/toview/web", q, expectedAccount: uid, as: Result.self)
    return .init(
      items: (r.list ?? []).filter { !$0.id.isEmpty },
      next: page * 20 < (r.count ?? 0) ? "\(page+1)" : nil, reportedTotal: r.count)
  }
  func history(cursor: String?, term: String = "", uid: String) async throws -> Page<Video> {
    struct Result: Decodable {
      struct Cursor: Decodable {
        let max: Int64
        let view_at: Int64
      }
      struct Row: Decodable {
        struct Entry: Decodable {
          let bvid: String?
          let business: String?
          let oid: Int64?
        }
        let history: Entry?
        let kid: Int64?
        let title: String?
        let cover: String?
        let author_name: String?
        let duration: Int?
      }
      let list: [Row]?
      let cursor: Cursor?
    }
    let c = cursor?.split(separator: ":").map(String.init) ?? ["0", "0"]
    let page = Int(cursor ?? "1") ?? 1
    let r: Result
    if term.isEmpty {
      r = try await read(
        "/x/web-interface/history/cursor",
        ["type": "archive", "ps": "20", "max": c.first ?? "0", "view_at": c.last ?? "0"],
        expectedAccount: uid, as: Result.self)
    } else {
      r = try await read(
        "/x/web-interface/history/search",
        ["business": "archive", "pn": "\(page)", "keyword": term], expectedAccount: uid,
        as: Result.self)
    }
    let items = (r.list ?? []).compactMap { row -> Video? in
      guard let id = row.history?.bvid, !id.isEmpty else { return nil }
      var item = Video.preview(
        id: id, title: row.title ?? id, cover: row.cover ?? "", author: row.author_name,
        duration: row.duration)
      item.aid = row.history?.oid
      if let kid = row.kid, let business = row.history?.business {
        item.historyKey = "\(business)_\(kid)"
      }
      return item
    }
    if !term.isEmpty {
      return .init(items: items, next: (r.list ?? []).isEmpty ? nil : "\(page+1)")
    }
    let next = r.cursor.map { "\($0.max):\($0.view_at)" }
    return .init(items: items, next: (r.list ?? []).isEmpty || next == cursor ? nil : next)
  }
  func folders(
    uid: String, videoID: Int64? = nil, resourceType: Int = 2, expectedAccount: String? = nil
  ) async throws -> [Folder] {
    struct Folders: Decodable { let list: [Folder]? }
    var fields = ["up_mid": uid]
    if let videoID {
      fields["rid"] = String(videoID)
      fields["type"] = String(resourceType)
    }
    return try await read(
      "/x/v3/fav/folder/created/list-all", fields, expectedAccount: expectedAccount,
      as: Folders.self
    )
    .list ?? []
  }
}
