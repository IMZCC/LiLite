import Foundation

enum NoticeMarkup {
  private static let rx = try! NSRegularExpression(
    pattern: #"#\{([^}]*)\}\{([^}]*)\}|https?://[^\s<>]+|www\.[^\s<>]+|【([^】]*)】|（([0-9]+)）"#)
  static func nodes(_ raw: String) -> [RichNode] {
    let s = String(raw.prefix(65536)) as NSString
    var result = [RichNode]()
    var at = 0
    func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
      let r = m.range(at: i)
      return r.location == NSNotFound ? nil : s.substring(with: r)
    }
    func target(_ link: String) -> RichNode.Target? {
      if let route = SharedLink.parse(link) { return .route(route) }
      let raw = link.hasPrefix("www.") ? "https://" + link : link
      guard let c = URLComponents(string: raw),
        ["http", "https"].contains(c.scheme?.lowercased() ?? ""), c.host != nil, c.user == nil,
        c.password == nil, let u = c.url
      else { return nil }
      return .url(u)
    }
    for m in rx.matches(in: s as String, range: NSRange(location: 0, length: s.length)) {
      if m.range.location > at {
        result.append(
          .init(text: s.substring(with: NSRange(location: at, length: m.range.location - at))))
      }
      let literal = s.substring(with: m.range)
      var node = RichNode(text: literal)
      if let label = group(m, 1), let link = group(m, 2),
        let t = target(link.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
      {
        node = .init(text: label.isEmpty ? "查看详情" : label, target: t)
      } else if let id = group(m, 3) {
        let route = SharedLink.parse(id) ?? Int64(id).flatMap { $0 > 0 ? .archive($0, nil) : nil }
        if let route { node = .init(text: id, target: .route(route)) }
      } else if let id = group(m, 4), let n = Int64(id), n > 0 {
        node = .init(text: "查看动态", target: .route(.dynamic(id)))
      } else if let t = target(literal) {
        node = .init(text: "网页链接", target: t)
      }
      result.append(node)
      at = NSMaxRange(m.range)
    }
    if at < s.length { result.append(.init(text: s.substring(from: at))) }
    return result
  }
  static func reply(_ raw: String?, oid: Int64?, business: Int?) -> SharedLink? {
    guard let raw, let oid, oid > 0, let business, [11,12,17].contains(business),
      let c = URLComponents(string:raw), c.scheme == "bilibili", c.host == "following",
      c.path.hasPrefix("/detail/"), let link = SharedLink.parse(raw),
      case .commentOn = link else { return nil }
    return link
  }
}
