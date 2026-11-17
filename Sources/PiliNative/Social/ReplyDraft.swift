import Foundation

/// Titles are editable text. Keep a URL only while its original text span remains intact.
struct ReplyDraft {
  private struct Link {
    var range: NSRange
    let url: String, kind: Int, business: String
  }
  private var links: [Link] = []
  private(set) var text = ""
  var raw: String {
    let out = NSMutableString(string: text)
    for link in links.sorted(by: { $0.range.location > $1.range.location }) {
      out.replaceCharacters(in: link.range, with: link.url)
    }
    return out as String
  }
  var markedRanges: [(range: NSRange, kind: Int, source: String)] {
    links.sorted { $0.range.location < $1.range.location }.map { ($0.range, $0.kind, $0.business) }
  }
  struct Piece: Equatable { let raw: String, kind: Int, business: String }
  var pieces: [Piece] {
    let s = text as NSString
    var result: [Piece] = []
    var from = 0
    for link in links.sorted(by: { $0.range.location < $1.range.location }) {
      if from < link.range.location {
        result.append(
          .init(
            raw: s.substring(with: .init(location: from, length: link.range.location - from)),
            kind: 1, business: ""))
      }
      result.append(.init(raw: link.url, kind: link.kind, business: link.business))
      from = NSMaxRange(link.range)
    }
    if from < s.length { result.append(.init(raw: s.substring(from: from), kind: 1, business: "")) }
    return result
  }
  /// Comments encode selected names as a dictionary, so two accounts with the same visible name are ambiguous.
  func mentionIDs() throws -> [String: Int64] {
    var ids = [String: Int64]()
    let units = pieces
    for (index, p) in units.enumerated() where p.kind == 2 && p.raw.hasPrefix("@") {
      if index + 1 < units.count, let next = units[index + 1].raw.first,
        next.isLetter || next.isNumber || next == "_"
      {
        continue
      }
      let name = String(p.raw.dropFirst())
      guard !name.isEmpty, let mid = Int64(p.business), mid > 0 else { continue }
      if let previous = ids[name], previous != mid {
        throw NSError(
          domain: "PiliNative.CommentMention", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "不能同时提及两个同名用户"])
      }
      ids[name] = mid
    }
    return ids
  }
  private static func valid(_ r: NSRange, _ length: Int) -> Bool {
    r.location >= 0 && r.location <= length && r.length >= 0 && r.length <= length - r.location
  }
  mutating func change(to next: String, hint: (NSRange, String)? = nil) {
    guard text != next else { return }
    let old = text as NSString
    let new = next as NSString
    if let (r, replacement) = hint, Self.valid(r, old.length),
      old.replacingCharacters(in: r, with: replacement) == next
    {
      _ = replace(r, with: replacement)
      return
    }
    // Autocorrect/IME may replace a range other than the proposed keyboard edit.
    var start = 0
    var suffix = 0
    while start < min(old.length, new.length), old.character(at: start) == new.character(at: start)
    { start += 1 }
    while suffix < min(old.length, new.length) - start,
      old.character(at: old.length - suffix - 1) == new.character(at: new.length - suffix - 1)
    { suffix += 1 }
    let r = NSRange(location: start, length: old.length - start - suffix)
    shift(r, count: new.length - start - suffix)
    text = next
  }
  private mutating func shift(_ range: NSRange, count: Int) {
    links = links.compactMap { old in
      if NSMaxRange(old.range) <= range.location { return old }
      if old.range.location >= NSMaxRange(range) {
        var moved = old
        moved.range.location += count - range.length
        return moved
      }
      return nil
    }
  }
  @discardableResult mutating func replace(
    _ selection: NSRange?, with token: String, url: String? = nil, kind: Int = 1,
    business: String = "", addSpace: Bool = true
  ) -> NSRange {
    let old = text as NSString
    let r =
      selection.flatMap { Self.valid($0, old.length) ? $0 : nil }
      ?? NSRange(location: old.length, length: 0)
    let inserted = token + (url != nil && addSpace ? " " : "")
    let count = (inserted as NSString).length
    shift(r, count: count)
    text = old.replacingCharacters(in: r, with: inserted)
    if let url, !url.isEmpty, !token.isEmpty {
      links.append(
        .init(
          range: .init(location: r.location, length: (token as NSString).length), url: url,
          kind: kind, business: business))
    }
    return .init(location: r.location + count, length: 0)
  }
}
