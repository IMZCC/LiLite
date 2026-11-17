import Foundation

struct DynamicRevision: Equatable {
  typealias Map = [String: Any]
  struct Picture: Equatable, Identifiable {
    let src: String, w: Double?, h: Double?, size: Double?, live: String?
    var id: String { src }
    var wire: Map {
      var p: Map = ["img_src": src]
      if let w { p["img_width"] = w }
      if let h { p["img_height"] = h }
      if let size { p["img_size"] = size }
      if let live { p["live_url"] = live }
      return p
    }
  }
  let id: String, author: String, origin: String?, title: String, pieces: [ReplyDraft.Piece],
    pictures: [Picture]
  let privateOnly: Bool, topicID: Int64?, topicName: String?, attached: String?
  let rootID: String?, rootType: Int?
  let reserveTitle: String?
  /// The edit target is the existing dynamic ID; published media remains owned by its separate service.
  let resourceID: String?
  static func referencedResource(type: String, major: Map) -> String? {
    let keys: [String: [String]] = [
      "DYNAMIC_TYPE_AV": ["archive"], "DYNAMIC_TYPE_UGC_SEASON": ["ugc_season"],
      "DYNAMIC_TYPE_PGC": ["pgc"], "DYNAMIC_TYPE_PGC_UNION": ["pgc"],
      "DYNAMIC_TYPE_COURSES_SEASON": ["courses"], "DYNAMIC_TYPE_MUSIC": ["music"],
      "DYNAMIC_TYPE_LIVE": ["live"], "DYNAMIC_TYPE_LIVE_RCMD": ["live_rcmd"],
      "DYNAMIC_TYPE_SUBSCRIPTION_NEW": ["subscription_new"],
      "DYNAMIC_TYPE_MEDIALIST": ["medialist"],
      "DYNAMIC_TYPE_COMMON_SQUARE": ["common", "upower_common"],
    ]
    for name in keys[type] ?? [] {
      guard var card = major[name] as? Map else { continue }
      if name == "subscription_new" { card = card["live_rcmd"] as? Map ?? [:] }
      if let encoded = card["content"] as? String, encoded.utf8.count <= 512 * 1024,
        let decoded = (try? JSONSerialization.jsonObject(with: Data(encoded.utf8))) as? Map,
        let live = decoded["live_play_info"] as? Map
      {
        card = live
      }
      for key in ["bvid", "aid", "epid", "room_id", "id", "season_id", "jump_url"] {
        if let value = number(card[key]), !value.isEmpty, value != "0" {
          return type + ":" + name + ":" + key + ":" + value
        }
      }
    }
    return nil
  }
  static func ownerPrivate(_ author: Map) -> Bool {
    let text =
      ((author["icon_badge"] as? Map)?["text"] as? String) ?? (author["badge_text"] as? String)
    return !(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
  }
  static func number(_ x: Any?) -> String? { (x as? String) ?? (x as? NSNumber)?.stringValue }
  init(row: Map, expected: String, id: String) throws {
    guard row["id_str"] as? String == id, let m = row["modules"] as? Map,
      let a = m["module_author"] as? Map, Self.number(a["mid"]) == expected,
      let d = m["module_dynamic"] as? Map
    else { throw ServiceError("只能编辑当前账号的动态") }
    self.id = id
    author = expected
    origin = (row["orig"] as? Map)?["id_str"] as? String
    let major = d["major"] as? Map
    let opus = major?["opus"] as? Map
    let desc = d["desc"] as? Map ?? opus?["summary"] as? Map
    title = opus?["title"] as? String ?? ""
    let basic = row["basic"] as? Map
    rootID = Self.number(basic?["comment_id_str"])
    rootType = (basic?["comment_type"] as? NSNumber)?.intValue
    let topic = d["topic"] as? Map
    topicID = Self.number(topic?["id"]).flatMap(Int64.init)
    topicName = topic?["name"] as? String
    privateOnly = Self.ownerPrivate(a)
    let add = d["additional"] as? Map
    let reserve = add?["reserve"] as? Map
    attached = Self.number(reserve?["rid"]).flatMap { (Int64($0) ?? 0) > 0 ? $0 : nil }
    reserveTitle = reserve?["title"] as? String
    let nodes = desc?["rich_text_nodes"] as? [Map] ?? []
    var parsed: [ReplyDraft.Piece] = nodes.compactMap { n in
      let token = n["orig_text"] as? String ?? n["text"] as? String ?? ""
      guard !token.isEmpty else { return nil }
      let kind: Int
      switch n["type"] as? String {
      case "RICH_TEXT_NODE_TYPE_AT": kind = 2
      case "RICH_TEXT_NODE_TYPE_VOTE": kind = 4
      case "RICH_TEXT_NODE_TYPE_EMOJI": kind = 9
      default: kind = 1
      }
      let biz = Self.number(n["rid"]) ?? ""
      return .init(
        raw: token, kind: (kind == 2 || kind == 4) && biz.isEmpty ? 1 : kind,
        business: kind == 2 || kind == 4 ? biz : "")
    }
    if parsed.isEmpty, let txt = desc?["text"] as? String, !txt.isEmpty {
      parsed.append(.init(raw: txt, kind: 1, business: ""))
    }
    if add?["type"] as? String == "ADDITIONAL_TYPE_VOTE", let vote = add?["vote"] as? Map,
      !parsed.contains(where: { $0.kind == 4 }), let id = Self.number(vote["vote_id"]),
      (Int64(id) ?? 0) > 0,
      let label = (vote["title"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? vote["desc"]
        as? String,
      !label.isEmpty
    {
      if !parsed.isEmpty { parsed.append(.init(raw: " ", kind: 1, business: "")) }
      parsed.append(.init(raw: label, kind: 4, business: id))
    }
    pieces = parsed
    let pics = opus?["pics"] as? [Map] ?? (major?["draw"] as? Map)?["items"] as? [Map] ?? []
    pictures = try pics.map { p in
      guard let u = p["url"] as? String ?? p["src"] as? String ?? p["img_src"] as? String,
        !u.isEmpty
      else { throw ServiceError("无法读取原图，请重新打开后编辑") }
      func d(_ a: String, _ b: String) -> Double? {
        (p[a] as? NSNumber ?? p[b] as? NSNumber)?.doubleValue
      }
      return Picture(
        src: u, w: d("width", "img_width"), h: d("height", "img_height"),
        size: d("size", "img_size"), live: p["live_url"] as? String)
    }
    let type = row["type"] as? String ?? ""
    resourceID = Self.referencedResource(type: type, major: major ?? [:])
    if resourceID == nil
      && ![
        "DYNAMIC_TYPE_DRAW", "DYNAMIC_TYPE_FORWARD", "DYNAMIC_TYPE_WORD", "DYNAMIC_TYPE_ARTICLE",
      ]
      .contains(type)
    {
      throw ServiceError("此类稿件请在创作中心编辑")
    }
    if let addType = add?["type"] as? String,
      !["ADDITIONAL_TYPE_NONE", "ADDITIONAL_TYPE_VOTE", "ADDITIONAL_TYPE_RESERVE"].contains(addType)
    {
      throw ServiceError("这条动态含有专用卡片，请在创作中心编辑")
    }
    if add?["type"] as? String == "ADDITIONAL_TYPE_RESERVE" && attached == nil {
      throw ServiceError("无法读取原预约卡片")
    }
    if add?["type"] as? String == "ADDITIONAL_TYPE_VOTE"
      && !pieces.contains(where: { $0.kind == 4 })
    {
      throw ServiceError("无法读取原投票卡片")
    }
    if type == "DYNAMIC_TYPE_ARTICLE" && (opus?["jump_url"] as? String ?? "").contains("/read/") {
      throw ServiceError("专栏稿件请在创作中心编辑")
    }
    if type == "DYNAMIC_TYPE_FORWARD" && origin == nil { throw ServiceError("原动态暂不可用") }
  }
  func editor() -> ReplyDraft {
    var result = ReplyDraft()
    for p in pieces {
      result.replace(
        nil, with: p.raw, url: p.kind == 1 ? nil : p.raw, kind: p.kind, business: p.business,
        addSpace: false)
    }
    return result
  }
  enum ReserveChange {
    case keep, remove
    case use(Int64)
  }
  func versionData() throws -> Data {
    var value: Map = [
      "id": id, "author": author, "title": title, "pics": pictures.map(\.wire),
      "parts": pieces.map { [$0.kind == 4 ? "" : $0.raw, String($0.kind), $0.business] },
      "private": privateOnly,
    ]
    value["resourceID"] = resourceID
    value["origin"] = origin
    value["topicID"] = topicID
    value["topicName"] = topicName
    value["reserve"] = attached
    value["oid"] = rootID
    value["type"] = rootType
    return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }
  func payload(
    contents: [ReplyDraft.Piece], title: String, pictures: [Map], topicID: Int64?,
    topicName: String?, isPrivate: Bool, replyMode: Int, uploadID: String,
    reserve: ReserveChange = .keep
  ) -> Map {
    var content: Map = [
      "contents": contents.map {
        ["raw_text": $0.raw, "type": $0.kind, "biz_id": $0.business] as Map
      }
    ]
    if !title.isEmpty { content["title"] = title }
    var opts = ["private_pub": isPrivate ? 1 : 0]
    if replyMode >= 0 {
      opts["close_comment"] = replyMode == 1 ? 1 : 0
      opts["up_choose_comment"] = replyMode == 2 ? 1 : 0
    }
    var dyn: Map = [
      "content": content, "scene": origin != nil ? 4 : pictures.isEmpty ? 1 : 2, "option": opts,
      "upload_id": uploadID,
      "meta": ["app_meta": ["from": "create.dynamic.web", "mobi_app": "web"]],
    ]
    if !pictures.isEmpty { dyn["pics"] = pictures }
    if let topicID, let topicName {
      dyn["topic"] =
        ["id": topicID, "name": topicName, "from_source": "dyn.web.list", "from_topic_id": 0] as Map
    }
    let chosen: String?
    switch reserve {
    case .keep: chosen = attached
    case .remove: chosen = nil
    case .use(let id): chosen = id > 0 ? String(id) : nil
    }
    if let attached = chosen {
      dyn["attach_card"] = [
        "common_card": ["type": 14, "biz_id": attached, "reserve_source": 0, "reserve_lottery": 0]
          as Map
      ]
    }
    var body: Map = ["dyn_req": dyn, "dyn_id_str": id]
    if let origin { body["web_repost_src"] = ["dyn_id_str": origin] }
    return body
  }
}
