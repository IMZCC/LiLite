import Foundation

struct RichNode: Hashable {
  enum Target: Hashable {
    case route(SharedLink)
    case url(URL)
    case search(String)
    case gallery([GalleryPicture])
    case pictureResource(String)
    case vote(Int64)
    case timestamp(Int)
  }
  struct Emote: Hashable {
    let name: String, url: URL, size: Int, jump: String?, jumpTitle: String?, animation: URL?
  }
  let text: String
  var bold = false, italic = false, strike = false
  var target: Target? = nil, emote: Emote? = nil
  static func parse(_ value: [String: Any]) -> RichNode? { parse(value, dynamicID: nil) }
  static func parse(_ value: [String: Any], dynamicID: String?) -> RichNode? {
    typealias Map = [String: Any]
    func string(_ v: Any?) -> String? {
      if let s = v as? String, !s.isEmpty { return s }
      if let n = v as? NSNumber { return n.stringValue }
      return nil
    }
    func link(_ raw: String?) -> Target? {
      guard let raw else { return nil }
      if let r = SharedLink.parse(raw) { return .route(r) }
      return GalleryPicture.source(raw).map(Target.url)
    }
    let kind = string(value["type"] ?? value["rich_text_node_type"]) ?? ""
    let original = string(value["orig_text"])
    let label = string(value["text"]) ?? original
    let rid = string(value["rid"])
    let jump = string(value["jump_url"])
    var n = RichNode(text: label ?? "")
    switch kind {
    case "RICH_TEXT_NODE_TYPE_TEXT":
      n = RichNode(text: original ?? label ?? "")
    case "RICH_TEXT_NODE_TYPE_EMOJI":
      if let e = value["emoji"] as? Map,
        let u = string(e["icon_url"] ?? e["url"]).flatMap(GalleryPicture.source)
      {
        let name = original ?? label ?? string(e["text"]) ?? "表情"
        n = RichNode(
          text: name,
          emote: .init(
            name: name, url: u, size: Int(string(e["size"]) ?? "") ?? 1,
            jump: string(e["jump_url"]), jumpTitle: string(e["jump_title"]),
            animation: string(e["webp_url"] ?? e["gif_url"]).flatMap(GalleryPicture.source)))
      }
    case "RICH_TEXT_NODE_TYPE_AT":
      if let mid = rid.flatMap(Int64.init), mid > 0 { n.target = .route(.creator(mid)) }
    case "RICH_TEXT_NODE_TYPE_TOPIC":
      let term = (original ?? n.text).trimmingCharacters(
        in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines))
      if !term.isEmpty { n.target = .search(term) }
    case "RICH_TEXT_NODE_TYPE_VOTE":
      if let id = rid.flatMap(Int64.init), id > 0 { n.target = .vote(id) }
    case "RICH_TEXT_NODE_TYPE_LOTTERY":
      if let id = dynamicID, let n = UInt64(id), n > 0, String(n) == id,
        let url = URL(string: "https://www.bilibili.com/h5/lottery/result?business_id=" + id)
      {
        return RichNode(text: original ?? label ?? "抽奖结果", target: .url(url))
      }
    case "RICH_TEXT_NODE_TYPE_BV":
      n.target = link(rid) ?? link(jump)
    case "RICH_TEXT_NODE_TYPE_VIEW_PICTURE":
      let pics = (value["pics"] as? [Map] ?? []).compactMap(GalleryPicture.init)
      if !pics.isEmpty { return RichNode(text: label ?? "查看图片", target: .gallery(pics)) }
      if let rid, let n = UInt64(rid), n > 0, String(n) == rid {
        return RichNode(text: label ?? "查看图片", target: .pictureResource(rid))
      }
      return label.map { RichNode(text: $0) }
    default: n.target = link(jump)
    }
    if n.target == nil && n.emote == nil { n.target = link(jump) }
    return n.text.isEmpty ? nil : n
  }
  static func body(_ raw: [String: Any]?, dynamicID: String? = nil) -> [Self] {
    ((raw?["rich_text_nodes"] as? [[String: Any]]) ?? []).compactMap {
      parse($0, dynamicID: dynamicID)
    }
  }
}

enum MomentPictureReply {
  static func photos(_ data: Data) throws -> [GalleryPicture] {
    struct Picture: Decodable { let src: String?, live_url: String? }
    struct Status: Decodable { let code: Int, message: String? }
    struct Envelope: Decodable { let data: [Picture]? }
    let code = try JSONDecoder().decode(Status.self, from: data)
    guard code.code == 0 else {
      throw NSError(
        domain: "PiliNative.MomentPictures", code: code.code,
        userInfo: [NSLocalizedDescriptionKey: code.message ?? "图片暂不可用"])
    }
    let rows = try JSONDecoder().decode(Envelope.self, from: data).data ?? []
    var seen = Set<URL>()
    return rows.compactMap { p in
      guard let src = p.src.flatMap(GalleryPicture.source), seen.insert(src).inserted else {
        return nil
      }
      return .init(src, motion: p.live_url.flatMap(GalleryPicture.source))
    }
  }
}
