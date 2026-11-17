import Foundation

enum MomentDestination: Hashable {
  case native(SharedLink)
  case web(URL)
  init?(_ raw: Any?) {
    guard var s = raw as? String, !s.isEmpty, s.utf8.count <= 8192 else { return nil }
    if s.hasPrefix("//") { s = "https:" + s }
    if let r = SharedLink.parse(s) {
      self = .native(r)
      return
    }
    guard let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
      u.host != nil, u.user == nil, u.password == nil
    else { return nil }
    self = .web(u)
  }
}
struct MomentReservation: Equatable {
  typealias Map = [String: Any]
  let id: Int64, title: String, sub1: String, prize: String, prizeLink: MomentDestination?,
    buttonType: Int?, disabled: Bool, checked: String, unchecked: String, jumpTitle: String?,
    jump: MomentDestination?
  var count: Int?, status: Int?, sub2: String
  private static func n(_ v: Any?) -> Int64? {
    (v as? NSNumber)?.int64Value ?? (v as? String).flatMap(Int64.init)
  }
  init?(_ m: Map?) {
    guard let m, let id = Self.n(m["rid"]), id > 0 else { return nil }
    self.id = id
    title = m["title"] as? String ?? "预约"
    func text(_ d: String) -> String { (m[d] as? Map)?["text"] as? String ?? "" }
    sub1 = text("desc1")
    sub2 = text("desc2")
    prize = text("desc3")
    prizeLink = MomentDestination((m["desc3"] as? Map)?["jump_url"])
    count = Self.n(m["reserve_total"]).flatMap(Int.init(exactly:))
    let b = m["button"] as? Map ?? [:]
    let off = b["uncheck"] as? Map ?? [:]
    status = Self.n(b["status"]).flatMap(Int.init(exactly:))
    buttonType = Self.n(b["type"]).flatMap(Int.init(exactly:))
    checked = (b["check"] as? Map)?["text"] as? String ?? "已预约"
    unchecked = off["text"] as? String ?? "预约"
    disabled = Self.n(off["disable"]) == 1
    jumpTitle = (b["jump_style"] as? Map)?["text"] as? String
    jump = MomentDestination(b["jump_url"])
  }
  var buttonLabel: String { jumpTitle ?? (status == buttonType ? checked : unchecked) }
  func intent(dynamic: String) -> Map? {
    guard let n = Int64(dynamic), n > 0, !disabled, jump == nil, let status, buttonType != nil
    else { return nil }
    var f: Map = ["reserve_id": id, "dynamic_id_str": dynamic, "cur_btn_status": status]
    if let count, count >= 0 { f["reserve_total"] = count }
    return f
  }
  func received(_ data: Map) -> Self? {
    guard let n = Self.n(data["final_btn_status"]).flatMap(Int.init(exactly:)) else { return nil }
    var copy = self
    copy.status = n
    if let total = Self.n(data["reserve_update"]).flatMap(Int.init(exactly:)), total >= 0 {
      copy.count = total
    }
    if let s = data["desc_update"] as? String { copy.sub2 = s }
    return copy
  }
}
struct MomentResources {
  typealias Map = [String: Any]
  struct Card { let title: String, sub: String, cover: URL?, target: MomentDestination? }
  let cards: [Card], reserve: MomentReservation?, pictures: [GalleryPicture]
  static func restricted(_ major: Map) -> Bool {
    major["blocked"] is Map || major["none"] is Map || major["type"] as? String == "MAJOR_TYPE_NONE"
  }
  static func likeStatus(_ row: Map) -> Bool? {
    guard let m = row["modules"] as? Map, let stats = m["module_stat"] as? Map,
      let like = stats["like"] as? Map
    else { return nil }
    if let value = like["status"] as? Bool { return value }
    if let s = like["status"] as? String {
      switch s {
      case "STATE_LIKE", "1", "true": return true
      case "STATE_NONE", "STATE_CANCEL", "0", "false": return false
      default: return nil
      }
    }
    return nil
  }
  static func dict(_ any: Any?) -> Map? {
    if let m = any as? Map { return m }
    if let s = any as? String, s.utf8.count <= 512 * 1024 {
      return (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? Map
    }
    return nil
  }
  init(_ module: Map, quotedID: String? = nil) {
    let m = module["major"] as? Map ?? [:]
    let a = module["additional"] as? Map ?? [:]
    if Self.restricted(m) {
      if let b = m["blocked"] as? Map {
        let btn = b["button"] as? Map
        cards = [
          .init(
            title: b["title"] as? String ?? "内容受限",
            sub: [b["hint_message"] as? String, btn?["text"] as? String].compactMap { $0 }.joined(
              separator: " · "), cover: nil, target: MomentDestination(btn?["jump_url"]))
        ]
      } else {
        cards = [
          .init(
            title: (m["none"] as? Map)?["tips"] as? String ?? "内容已失效", sub: "", cover: nil,
            target: nil)
        ]
      }
      reserve = nil
      pictures = []
      return
    }
    reserve = MomentReservation(a["reserve"] as? Map)
    if quotedID != nil {
      let opus = m["opus"] as? Map
      let draw = m["draw"] as? Map
      pictures = (opus?["pics"] as? [Map] ?? draw?["items"] as? [Map] ?? []).compactMap(
        GalleryPicture.init)
    } else {
      pictures = []
    }
    var rows = [Card]()
    func s(_ v: Any?) -> String? {
      if let t = v as? String, !t.isEmpty { return t }
      if let d = v as? Map, let t = d["text"] as? String, !t.isEmpty { return t }
      if let n = v as? NSNumber { return n.stringValue }
      return nil
    }
    func n(_ v: Any?) -> Int64? { s(v).flatMap(Int64.init).flatMap { $0 > 0 ? $0 : nil } }
    func card(
      _ title: Any?, _ details: [Any?], _ cover: Any?, _ link: Any?,
      fallback: MomentDestination? = nil
    ) {
      let sub = details.compactMap(s).joined(separator: " · ")
      let pic = s(cover).flatMap(GalleryPicture.source)
      let target = MomentDestination(link) ?? fallback
      guard let title = s(title) ?? (target == nil ? nil : "查看详情") else { return }
      rows.append(.init(title: title, sub: sub, cover: pic, target: target))
    }
    if let original = quotedID {
      if let c = m["archive"] as? Map {
        card(
          c["title"], [c["desc"]], c["cover"], c["jump_url"],
          fallback: (c["bvid"] as? String).flatMap(SharedLink.parse).map(MomentDestination.native))
      }
      if let attachment = DynamicModules([:], major: m).attachment {
        rows.append(
          .init(
            title: attachment.title, sub: "", cover: attachment.cover,
            target: .native(attachment.route)))
      }
      if let opus = m["opus"] as? Map {
        card(opus["title"] ?? "阅读图文", [], nil, nil, fallback: .native(.opus(original)))
      }
      if let t = module["topic"] as? Map, let tid = n(t["id"]), let name = s(t["name"]) {
        card("#" + name, [], nil, nil, fallback: .native(.topic(tid)))
      }
      if let v = a["vote"] as? Map, let id = n(v["vote_id"]) {
        card(v["desc"] ?? "查看投票", [], nil, nil, fallback: .native(.vote(id)))
      }
    }
    if let live = m["live"] as? Map {
      card(
        live["title"], [live["desc_first"], live["badge"]], live["cover"], live["jump_url"],
        fallback: n(live["id"]).map { .native(.room($0)) })
    }
    for outer in [m["live_rcmd"] as? Map, (m["subscription_new"] as? Map)?["live_rcmd"] as? Map]
      .compactMap({ $0 })
    {
      if let l = Self.dict(outer["content"])?["live_play_info"] as? Map {
        card(
          l["title"], [l["area_name"], (l["watched_show"] as? Map)?["text_large"]], l["cover"],
          l["link"], fallback: n(l["room_id"]).map { .native(.room($0)) })
      }
    }
    if let music = m["music"] as? Map {
      card(
        music["title"], [music["label"]], music["cover"], nil,
        fallback: n(music["id"]).map { .native(.song($0)) })
    }
    if let article = m["article"] as? Map {
      card(
        article["title"], [article["desc"], article["label"]],
        (article["covers"] as? [String])?.first, article["jump_url"],
        fallback: n(article["id"]).map { .native(.article($0)) })
    }
    for key in ["common", "upower_common", "medialist"] {
      if let c = m[key] as? Map {
        card(c["title"], [c["desc"], c["sub_title"], c["badge"]], c["cover"], c["jump_url"])
      }
    }
    func extraLink(_ c: Map?, defaultLabel: String) {
      guard let c, let url = MomentDestination(c["jump_url"]) else { return }
      let label = s(c["jump_style"]) ?? s(c["check"]) ?? s(c["text"]) ?? defaultLabel
      rows.append(.init(title: label, sub: "", cover: nil, target: url))
    }
    if let c = a["ugc"] as? Map { card(c["title"], [c["desc_second"]], c["cover"], c["jump_url"]) }
    if let c = a["common"] as? Map {
      card(c["title"], [c["desc1"], c["desc2"]], c["cover"], c["jump_url"])
      extraLink(c["button"] as? Map, defaultLabel: "查看详情")
    }
    if let c = a["upower_lottery"] as? Map {
      card(c["title"], [c["hint"], c["desc"]], c["cover"], c["jump_url"])
      extraLink(c["desc"] as? Map, defaultLabel: "查看奖品")
      extraLink(c["button"] as? Map, defaultLabel: "查看活动")
    }
    for p in ((a["goods"] as? Map)?["items"] as? [Map] ?? []) {
      card(p["name"], [p["price"], p["jump_desc"]], p["cover"], p["jump_url"])
    }
    if let c = a["match"] as? Map, let info = c["match_info"] as? Map {
      let score = (info["center_top"] as? [Any] ?? []).compactMap(s).joined(separator: " ")
      card(
        info["title"],
        [
          info["sub_title"], (info["left_team"] as? Map)?["name"], score, info["center_bottom"],
          (info["right_team"] as? Map)?["name"],
        ], (info["left_team"] as? Map)?["pic"], c["jump_url"])
      extraLink(c["button"] as? Map, defaultLabel: "查看赛事")
    }
    cards = rows
  }
}

struct MomentMentionGroup: Decodable {
  struct User: Decodable, Identifiable {
    let face: String?, fans: Int?, name: String?, uid: String?
    enum Keys: String, CodingKey { case face, fans, name, uid }
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: Keys.self)
      face = try? c.decode(String.self, forKey: .face)
      name = try? c.decode(String.self, forKey: .name)
      fans =
        (try? c.decode(Int.self, forKey: .fans))
        ?? (try? c.decode(String.self, forKey: .fans)).flatMap(Int.init)
      uid =
        (try? c.decode(String.self, forKey: .uid))
        ?? (try? c.decode(Int64.self, forKey: .uid)).map(String.init)
    }
    var id: String { uid ?? "" }
  }
  let group_name: String?, items: [User]?
}
