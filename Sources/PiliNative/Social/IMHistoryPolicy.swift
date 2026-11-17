import Foundation

enum IMHistoryPolicy {
  static func older(flag: Bool, minimum: Int64?, sequences: [Int64], before: Int64?) -> String? {
    guard flag else { return nil }
    let n = (minimum ?? 0) > 0 ? minimum : sequences.filter { $0 > 0 }.min()
    guard let n, n > 0, before.map({ n < $0 }) ?? true else { return nil }
    return String(n)
  }
  static func key(_ value: String?) -> String? {
    guard let value else { return nil }
    if let raw = UInt64(value), raw != 0 { return String(raw) }
    if let n = Int64(value), n < 0 { return String(UInt64(bitPattern: n)) }
    return nil
  }
  static func recall(_ text: String?) -> String? {
    guard let text else { return nil }
    if let raw = key(text) { return raw }
    let payload = try? JSONSerialization.jsonObject(
      with: Data(text.utf8), options: .fragmentsAllowed)
    if let scalar = payload as? String { return key(scalar) }
    if let d = payload as? [String: Any] {
      let n = d["msg_key"] ?? d["msgKey"]
      return key(n as? String ?? (n as? NSNumber)?.stringValue)
    }
    return nil
  }
  static func tokenize(_ value: String, emotes: [String: RichNode.Emote]) -> [RichNode] {
    let ns = value as NSString
    guard ns.length > 0 else { return [] }
    var ranges = [(NSRange, RichNode)]()
    if let regex = web {
      for match in regex.matches(in: value, range: NSRange(location: 0, length: ns.length)) {
        let raw = ns.substring(with: match.range)
        if let url = GalleryPicture.source(raw) {
          ranges.append(
            (
              match.range,
              .init(
                text: raw, target: SharedLink.parse(raw).map(RichNode.Target.route) ?? .url(url))
            ))
        }
      }
    }
    // Only names actually present in the page dictionary become attachments.
    var pos = 0
    while pos < ns.length {
      let scan = NSRange(location: pos, length: ns.length - pos)
      let left = ns.range(of: "[", options: [], range: scan)
      guard left.location != NSNotFound else { break }
      let start = left.location + 1
      let end = ns.range(
        of: "]", options: [], range: NSRange(location: start, length: min(256, ns.length - start)))
      if end.location != NSNotFound {
        let span = NSRange(location: left.location, length: NSMaxRange(end) - left.location)
        let token = ns.substring(with: span)
        if let e = emotes[token] {
          ranges.append((span, .init(text: token, emote: e)))
          pos = NSMaxRange(end)
          continue
        }
      }
      pos = start
    }
    ranges.sort {
      $0.0.location == $1.0.location ? $0.0.length > $1.0.length : $0.0.location < $1.0.location
    }
    var out = [RichNode]()
    pos = 0
    for (r, node) in ranges where r.location >= pos {
      if r.location > pos {
        out.append(
          .init(text: ns.substring(with: NSRange(location: pos, length: r.location - pos))))
      }
      out.append(node)
      pos = NSMaxRange(r)
    }
    if pos < ns.length { out.append(.init(text: ns.substring(from: pos))) }
    return out
  }
  private static let web = try? NSRegularExpression(
    pattern: #"https?://[-A-Za-z0-9+&@#/%?=~_|!:,.;]+[-A-Za-z0-9+&@#/%=~_|]"#)
}
