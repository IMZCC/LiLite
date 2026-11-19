import Foundation

enum SearchDomain: String, CaseIterable {
  case mixed = "综合"
  case video = "视频"
  case creator = "用户"
  case bangumi = "番剧"
  case cinema = "影视"
  case live = "直播间"
  case article = "专栏"
  /// The original's result tabs: videos live under 综合 (which becomes a video search once a
  /// filter is set), so there is no separate 视频 tab.
  static let tabs: [SearchDomain] = [.mixed, .bangumi, .cinema, .live, .creator, .article]
  var service: String {
    switch self {
    case .video: return "video"
    case .creator: return "bili_user"
    case .bangumi: return "media_bangumi"
    case .cinema: return "media_ft"
    case .live: return "live_room"
    case .article: return "article"
    case .mixed: return "all"
    }
  }
}
struct SearchHit: Identifiable {
  struct Card { let title: String, cover: String?, description: String }
  struct Person { let creator: Creator, room: Int64?, meta: String, uploads: [Video] }
  enum Content {
    case video(Video)
    case person(Person)
    case link(SharedLink, Card)
    case external(URL, Card)
  }
  let id: String, content: Content
  var embeddedVideoTarget = false
  var archiveID: Int64? {
    if case .video(let v) = content { return v.aid }
    return nil
  }
  static func num(_ x: Any?) -> Int64? {
    (x as? NSNumber)?.int64Value ?? (x as? String).flatMap(Int64.init)
  }
  static func text(_ x: Any?) -> String {
    (x as? String ?? "").replacingOccurrences(
      of: "</?em(?:\\s[^>]*)?>", with: "", options: .regularExpression
    ).replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")
  }
  static func video(_ r: [String: Any]) -> Video? {
    let aid = num(r["aid"])
    guard
      let bv = (r["bvid"] as? String).flatMap({ $0.isEmpty ? nil : $0 })
        ?? aid.flatMap(ArchiveNumber.bv), !bv.isEmpty
    else { return nil }
    let seconds =
      (r["duration"] as? String)?.split(separator: ":").compactMap { Int($0) }.reduce(0) {
        $0 * 60 + $1
      } ?? num(r["duration"]).map(Int.init)
    return Video(
      pubdate: num(r["pubdate"]), aid: aid, bvid: bv, title: text(r["title"]), pic: text(r["pic"]),
      owner: .init(mid: num(r["mid"]), name: r["author"] as? String),
      stat: .init(
        like: num(r["like"]).map(Int.init), view: num(r["play"]).map(Int.init),
        danmaku: num(r["danmaku"]).map(Int.init)), duration: seconds,
      desc: r["description"] as? String, cid: nil, pages: nil)
  }
  static func decode(_ kind: String, _ r: [String: Any], blocked: Set<Int64>) -> [Self] {
    let mid = num(r["mid"] ?? r["uid"]) ?? 0
    if ["video", "bili_user", "live_room", "article"].contains(kind), blocked.contains(mid) {
      return []
    }
    let title = text(r["title"])
    func card(_ extra: [String?], cover: String? = nil) -> Card {
      .init(
        title: title, cover: cover,
        description: extra.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
    }
    switch kind {
    case "video":
      if text(r["type"]) == "live_room", let room = num(r["roomid"]), room > 0 {
        return [
          .init(
            id: "r\(room)",
            content: .link(
              .room(room), card(["直播", text(r["author"])], cover: r["pic"] as? String)),
            embeddedVideoTarget: true)
        ]
      }
      if text(r["type"]) == "ketang", let s = num(r["aid"]), s > 0 {
        return [
          .init(
            id: "c\(s)",
            content: .link(
              .course(s, false), card(["课堂", text(r["author"])], cover: r["pic"] as? String)),
            embeddedVideoTarget: true)
        ]
      }
      guard let v = video(r) else { return [] }
      return [.init(id: "v" + v.id, content: .video(v))]
    case "bili_user":
      guard mid > 0 else { return [] }
      let p = Creator(
        mid: mid, uname: text(r["uname"]), face: r["upic"] as? String, sign: r["usign"] as? String)
      let meta = [
        num(r["level"]).map { "Lv.\($0)" },
        num(r["fans"]).map { "\($0.formatted(.number.notation(.compactName))) 粉丝" },
        num(r["videos"]).map { "\($0) 个视频" },
        (r["official_verify"] as? [String: Any])?["desc"] as? String,
      ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
      let room = num(r["is_live"]) == 1 ? num(r["room_id"] ?? r["roomid"]) : nil
      let videos = (r["res"] as? [[String: Any]] ?? []).compactMap { video($0) }
      return [
        .init(
          id: "u\(mid)",
          content: .person(.init(creator: p, room: room, meta: meta, uploads: videos)))
      ]
    case "media_bangumi", "media_ft":
      guard let s = num(r["season_id"]), s > 0 else { return [] }
      let mediaScore=(r["media_score"] as? [String:Any])?["score"]
      let rating=(mediaScore as? NSNumber)?.doubleValue ?? (mediaScore as? String).flatMap(Double.init)
      let score=rating.flatMap{v in v.isFinite && v>0 && v<=10 ? "评分 "+v.formatted() : nil}
      let year=num(r["pubtime"]).flatMap{t->String? in
        guard t>0,t<253_402_300_799 else{return nil};var cal=Calendar(identifier:.gregorian);cal.timeZone=TimeZone(secondsFromGMT:8*3600)!
        return String(cal.component(.year,from:Date(timeIntervalSince1970:Double(t))))+" 年"
      }
      return [
        .init(
          id: "s\(s)",
          content: .link(
            .season(s),
            card(
              [
                text(r["season_type_name"]), text(r["index_show"]), text(r["areas"]),
                year,score,text(r["styles"]), text(r["desc"]),
              ], cover: r["cover"] as? String)))
      ]
    case "live_room":
      guard let room = num(r["roomid"]), room > 0 else { return [] }
      return [
        .init(
          id: "r\(room)",
          content: .link(
            .room(room),
            card(
              [text(r["uname"]), text(r["cate_name"]), num(r["online"]).map { "\($0) 人气" }],
              cover: r["cover"] as? String)))
      ]
    case "article":
      guard let id = num(r["id"]), id > 0 else { return [] }
      return [
        .init(
          id: "a\(id)",
          content: .link(
            .article(id),
            card(
              [text(r["category_name"]), text(r["desc"])],
              cover: (r["image_urls"] as? [String])?.first)))
      ]
    case "activity":
      guard let url = (r["url"] as? String).flatMap(httpsURL), url.host == "live.bilibili.com"
      else { return [] }
      let c = card([text(r["author"]), text(r["desc"])], cover: r["cover"] as? String)
      return [
        .init(
          id: "l" + url.absoluteString,
          content: SharedLink.parse(url.absoluteString).map { .link($0, c) } ?? .external(url, c))
      ]
    case "esports":
      return (r["contest"] as? [[String: Any]] ?? []).compactMap { m in
        guard let id = num(m["ID"]), id > 0 else { return nil }
        let teams = [m["homeTeam"], m["awayTeam"]].compactMap {
          ($0 as? [String: Any])?["title"] as? String
        }.joined(separator: " vs ")
        let stage = text(m["gameStage"])
        return .init(
          id: "m\(id)",
          content: .link(
            .match(id), .init(title: teams.isEmpty ? stage : teams, cover: nil, description: stage))
        )
      }
    default: return []
    }
  }
}

struct VideoSearchOptions: Equatable {
  var order = "totalrank", duration = 0, zone = 0, dates = 0
  var begin: Date =
    Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))
    ?? Date()
  var end = Date()
  var filtered: Bool { order != "totalrank" || duration != 0 || zone != 0 || dates != 0 }
  func fields(now: Date = Date(), calendar: Calendar = .current) -> [String: String] {
    var q = ["duration": String(duration)]
    if order != "totalrank" { q["order"] = order }
    if zone != 0 { q["tids"] = String(zone) }
    if dates != 0 {
      let stop = calendar.startOfDay(for: dates == -1 ? min(end, now) : now)
      let start: Date
      if dates == -1 {
        start = calendar.startOfDay(for: min(begin, stop))
      } else {
        start = calendar.date(byAdding: .day, value: -(dates - 1), to: stop) ?? stop
      }
      q["pubtime_begin_s"] = String(Int(start.timeIntervalSince1970))
      q["pubtime_end_s"] = String(
        Int(
          (calendar.date(byAdding: .day, value: 1, to: stop) ?? stop.addingTimeInterval(86400))
            .timeIntervalSince1970) - 1)
    }
    return q
  }
  var key: String {
    fields().sorted { $0.key < $1.key }.map { $0.key + ":" + $0.value }.joined(separator: ",")
  }
  static let orders = [
    ("totalrank", "综合"), ("click", "最多播放"), ("pubdate", "最新发布"), ("dm", "最多弹幕"), ("stow", "最多收藏"),
    ("scores", "最多评论"),
  ]
  static let zones = [
    (0, "全部分区"), (1, "动画"), (13, "番剧"), (167, "国创"), (3, "音乐"), (129, "舞蹈"), (4, "游戏"), (36, "知识"),
    (188, "科技"), (234, "运动"), (223, "汽车"), (160, "生活"), (221, "美食"), (217, "动物"), (119, "鬼畜"),
    (115, "时尚"), (202, "资讯"), (5, "娱乐"), (181, "影视"), (177, "纪录片"), (23, "电影"), (11, "电视"),
  ]
}
struct OtherSearchOptions: Equatable {
  var userOrder = 0, userType = 0, articleOrder = "totalrank", articleZone = 0
  static let users = [
    ("", "默认", 0), ("fans", "粉丝数从高到低", 0), ("fans", "粉丝数从低到高", 1), ("level", "等级从高到低", 0),
    ("level", "等级从低到高", 1),
  ]
  static let articles = [
    ("totalrank", "综合"), ("pubdate", "最新发布"), ("click", "最多点击"), ("attention", "最多喜欢"),
    ("scores", "最多评论"),
  ]
  static let zones = [
    (0, "全部分区"), (2, "动画"), (1, "游戏"), (28, "影视"), (3, "生活"), (29, "兴趣"), (16, "轻小说"), (17, "科技"),
    (41, "笔记"),
  ]
  func fields(_ domain: SearchDomain) -> [String: String] {
    switch domain {
    case .creator:
      let order = Self.users.indices.contains(userOrder) ? Self.users[userOrder] : Self.users[0]
      var values = ["user_type": String(userType), "order_sort": String(order.2)]
      if !order.0.isEmpty { values["order"] = order.0 }
      return values
    case .article: return ["order": articleOrder, "category_id": String(articleZone)]
    default: return [:]
    }
  }
}

struct SeasonIndexCondition: Decodable {
  struct Order: Decodable { let field: String, name: String }
  struct Filter: Decodable {
    struct Value: Decodable { let keyword: String, name: String }
    let field: String, name: String, values: [Value]?
  }
  let order: [Order]?, filter: [Filter]?
  func firstChoices() -> [String: String] {
    var result = [String: String]()
    result["order"] = order?.first?.field
    for f in filter ?? []
    where !["page", "pagesize", "season_type", "type", "index_type", "order"].contains(f.field) {
      result[f.field] = f.values?.first?.keyword
    }
    return result
  }
}

enum DiscoveryRanking: Hashable, Identifiable {
  case video(Int, String)
  case season(Int, String)
  var id: Self { self }
  var title: String {
    switch self {
    case .video(_, let s), .season(_, let s): return s
    }
  }
  static let all: [Self] = [
    .video(0, "全站"), .season(1, "番剧"), .season(4, "国创"), .video(1005, "动画"), .video(1003, "音乐"),
    .video(1004, "舞蹈"),
    .video(1008, "游戏"), .video(1010, "知识"), .video(1012, "科技"), .video(1018, "运动"),
    .video(1013, "汽车"),
    .video(1020, "美食"), .video(1024, "动物"), .video(1007, "鬼畜"), .video(1014, "时尚"),
    .video(1002, "娱乐"), .video(1001, "影视"),
    .season(3, "纪录片"), .season(2, "电影"), .season(5, "剧集"), .season(7, "综艺"),
  ]
}

enum SearchNumber {
  static func positive(_ text: String) -> Int64? {
    guard !text.isEmpty, text.utf8.allSatisfy({ 48...57 ~= $0 }), let n = Int64(text), n > 0 else {
      return nil
    }
    return n
  }
  static func matched(_ text: String, rows: [SearchHit]) -> Int64? {
    guard let n = positive(text) else { return nil }
    // Blended pages put user and media modules before the first entry of the video bucket.
    // A live or course result in that bucket must not let a later matching archive auto-open.
    let first = rows.first { r in
      if case .video = r.content { return true }
      return r.embeddedVideoTarget
    }
    return first?.archiveID == n ? n : nil
  }
}
