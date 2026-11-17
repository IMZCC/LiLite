import Foundation

struct ArticleSpan: Equatable {
  var value: String, bold = false, italic = false, strike = false
  var url: URL?
  var node: RichNode? = nil
  var formula: String? = nil, fontSize: Double? = nil, hexRGB: UInt32? = nil, lottery = false
  func inline(heading: Bool = false, quote: Bool = false) -> RichNode {
    var n = node ?? RichNode(text: value, target: url.map(RichNode.Target.url))
    n.bold = bold || heading
    n.italic = italic || quote
    n.strike = strike
    return n
  }
}
struct ArticleResource: Equatable {
  var title: String, detail: String = "", cover: URL?, target: RichNode.Target?
  static func parse(_ card: [String: Any]) -> [Self] {
    typealias M = [String: Any]
    func text(_ value: Any?) -> String? {
      if let s = value as? String, !s.isEmpty { return s }
      if let n = value as? NSNumber { return n.stringValue }
      if let m = value as? M { return text(m["text"] ?? m["title"]) }
      return nil
    }
    func route(_ v: Any?) -> RichNode.Target? {
      guard var s = text(v) else { return nil }
      if s.hasPrefix("//") { s = "https:" + s }
      if let r = SharedLink.parse(s) { return .route(r) }
      if let u = URL(string: s), ["https", "http"].contains(u.scheme?.lowercased() ?? ""),
        u.host != nil, u.user == nil, u.password == nil
      {
        return .url(u)
      }
      return nil
    }
    func id(_ value: Any?) -> Int64? {
      text(value).flatMap(Int64.init).flatMap { $0 > 0 ? $0 : nil }
    }
    let raw = card["type"] as? String ?? ""
    let k = raw.replacingOccurrences(of: "LINK_CARD_TYPE_", with: "").lowercased()
    guard let c = card[k] as? M else { return [] }
    let f = c["info"] as? M ?? c
    if k == "goods" {
      return (c["items"] as? [M] ?? []).compactMap { i in
        guard let n = text(i["name"]) else { return nil }
        return .init(
          title: n,
          detail: [i["price"], i["brief"], i["jump_desc"]].compactMap(text).joined(
            separator: " · "), cover: text(i["cover"]).flatMap(GalleryPicture.source),
          target: route(i["jump_url"]))
      }
    }
    let user = f["user"] as? M
    let title =
      text(f["title"] ?? f["name"] ?? f["text"] ?? f["link_show_text"] ?? user?["name"])
      ?? (k == "vote" || k == "eva3_vote" ? "投票" : nil)
    guard let title else { return [] }
    var target = route(f["jump_url"] ?? f["jump_uri"] ?? c["resource_url"])
    switch k {
    case "vote", "eva3_vote": if let n = id(f["vote_id"] ?? card["oid"]) { target = .vote(n) }
    case "eva3_user": if let n = id(user?["mid"]) { target = .route(.creator(n)) }
    case "music": if target == nil, let n = id(f["id"]) { target = .route(.song(n)) }
    case "live": if target == nil, let n = id(f["id"]) { target = .route(.room(n)) }
    case "item_null": target = nil
    default: break
    }
    let art = f["cover"] ?? f["poster"] ?? user?["face"]
    let pic = text(art ?? (f["covers"] as? [String])?.first ?? (f["pics"] as? [M])?.first?["src"])
      .flatMap(GalleryPicture.source)
    let detail = [
      f["desc_first"], f["content"], (f["author"] as? M)?["name"], f["desc"], f["desc1"],
      f["desc2"], f["desc_second"], f["label"], f["author_name"], f["view"], f["reply"],
      f["stat_text"], (f["source"] as? M)?["desc"],
    ].compactMap(text).joined(separator: " · ")
    return [.init(title: title, detail: detail, cover: pic, target: target)]
  }
}
enum ArticleBlock: Equatable {
  case card(ArticleResource)
  case paragraph([ArticleSpan])
  case heading([ArticleSpan])
  case quote([ArticleSpan])
  case code(String)
  case image(URL, String)
  case motion(GalleryPicture, String)
  var picture: GalleryPicture? {
    switch self {
    case .image(let u, _): return .init(u)
    case .motion(let p, _): return p
    default: return nil
    }
  }
  case divider
}
enum ArticleBody {
  typealias Object = [String: Any]
  static func spans(_ node: Object) -> [ArticleSpan] {
    (node["nodes"] as? [Object] ?? []).compactMap { n in
      let w = n["word"] as? Object
      let r = n["rich"] as? Object
      let style = (w?["style"] ?? r?["style"]) as? Object
      let rich = r.flatMap(RichNode.parse)
      guard
        let text =
          (w?["words"] ?? rich?.text ?? r?["text"] ?? r?["orig_text"]
          ?? (n["formula"] as? Object)?["latex_content"]) as? String, !text.isEmpty
      else { return nil }
      return ArticleSpan(
        value: text, bold: style?["bold"] as? Bool ?? false,
        italic: style?["italic"] as? Bool ?? false,
        strike: style?["strikethrough"] as? Bool ?? false,
        url: (r?["jump_url"] as? String).flatMap(httpsURL),
        node: rich.flatMap { $0.target == nil && $0.emote == nil ? nil : $0 },
        formula: (n["formula"] as? Object)?["latex_content"] as? String,
        fontSize: (w?["font_size"] as? NSNumber)?.doubleValue
          ?? ["small": 13.0, "xxLarge": 24.0][
            (w?["font_level"] ?? style?["font_level"]) as? String ?? ""],
        hexRGB: (w?["color"] as? String).flatMap {
          $0.count == 7 && $0.hasPrefix("#") ? UInt32($0.dropFirst(), radix: 16) : nil
        }, lottery: r?["type"] as? String == "RICH_TEXT_NODE_TYPE_LOTTERY")
    }
  }
  /// The older /x/article/view type 3 format is Quill ops, not the HTML version of the article.
  static func legacyOps(_ values: [Object]) -> [ArticleBlock] {
    var blocks = [ArticleBlock]()
    var line = [ArticleSpan]()
    func emit() {
      if !line.isEmpty {
        blocks.append(.paragraph(line))
        line = []
      }
    }
    for op in values {
      let attr = op["attributes"] as? Object ?? [:]
      if let raw = op["insert"] as? String {
        let parts = raw.components(separatedBy: "\n")
        for (i, part) in parts.enumerated() {
          if i > 0 { emit() }
          if !part.isEmpty {
            line.append(
              .init(
                value: part, bold: attr["bold"] as? Bool == true,
                italic: attr["italic"] as? Bool == true, strike: attr["strike"] as? Bool == true,
                url: (attr["link"] as? String).flatMap(httpsURL)))
          }
        }
        continue
      }
      guard let embeds = op["insert"] as? Object else { continue }
      emit()
      for key in [
        "article-card", "video-card", "vote-card", "live-card", "goods-card", "mall-card",
      ] {
        guard let value = embeds[key] as? Object else { continue }
        let id = (value["id"] as? String) ?? (value["id"] as? NSNumber)?.stringValue ?? ""
        let target: RichNode.Target?
        switch key {
        case "article-card", "video-card": target = SharedLink.parse(id).map(RichNode.Target.route)
        case "vote-card": target = Int64(id).flatMap { $0 > 0 ? RichNode.Target.vote($0) : nil }
        case "live-card":
          target = Int64(id).flatMap { $0 > 0 ? RichNode.Target.route(.room($0)) : nil }
        default: target = (value["jump_url"] as? String).flatMap(httpsURL).map(RichNode.Target.url)
        }
        let title =
          (value["alt"] as? String) ?? [
            "video-card": "视频", "article-card": "专栏", "live-card": "直播", "vote-card": "投票",
            "goods-card": "商品", "mall-card": "商品",
          ][key] ?? "查看内容"
        blocks.append(
          .card(
            .init(
              title: title, cover: (value["url"] as? String).flatMap(GalleryPicture.source),
              target: target)))
        break
      }
    }
    emit()
    return blocks
  }
  static func opus(_ rows: [Object], depth: Int = 0) -> [ArticleBlock] {
    guard depth < 16 else { return [] }
    var out: [ArticleBlock] = []
    for i in rows {
      if let h = i["heading"] as? Object {
        let a = spans(h)
        if !a.isEmpty { out.append(.heading(a)) }
      }
      if let t = i["text"] as? Object {
        let a = spans(t)
        if !a.isEmpty { out.append((i["para_type"] as? Int) == 4 ? .quote(a) : .paragraph(a)) }
      }
      if let pic = i["pic"] as? Object {
        for p in pic["pics"] as? [Object] ?? [pic] {
          if let photo = GalleryPicture(p) {
            let caption = p["desc"] as? String ?? ""
            out.append(photo.motion == nil ? .image(photo.url, caption) : .motion(photo, caption))
          }
        }
      }
      if let line = i["line"] as? Object {
        if let url = ((line["pic"] as? Object)?["url"] as? String).flatMap(httpsURL) {
          out.append(.image(url, ""))
        } else {
          out.append(.divider)
        }
      }
      if let code = (i["code"] as? Object)?["content"] as? String { out.append(.code(code)) }
      if let quote = (i["blockquote"] as? Object)?["children"] as? [Object] {
        out += opus(quote, depth: depth + 1).map {
          if case .paragraph(let s) = $0 { return .quote(s) }
          return $0
        }
      }
      if let list = i["list"] as? Object {
        for element in list["items"] as? [Object] ?? [] {
          var a = spans(element)
          if !a.isEmpty {
            a.insert(.init(value: (element["order"] as? Int).map { "\($0). " } ?? "• "), at: 0)
            out.append(.paragraph(a))
          }
        }
        for child in list["children"] as? [Object] ?? [] {
          out += opus(child["children"] as? [Object] ?? [], depth: depth + 1)
        }
      }
      if let card = (i["link_card"] as? Object)?["card"] as? Object {
        let cards = ArticleResource.parse(card)
        if !cards.isEmpty {
          out += cards.map(ArticleBlock.card)
        } else if let title = card["title"] as? String {
          out.append(.paragraph([.init(value: title)]))
        }

      }
    }
    return out
  }
}
