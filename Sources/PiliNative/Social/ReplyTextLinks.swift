import SwiftUI

/// Per-row memoization, without publishing another view update when an emote or layout changes.
/// Keep every input used by InlineDocument in the comparison, including translated/link metadata.
@MainActor final class ReplyDocumentCache {
  private var previous: Reply.Content?
  private var wordSearch = false
  private var duration: Double?
  private var value = InlineDocument(text: "")

  func document(reply: Reply.Content, wordSearch: Bool, duration: Double?) -> InlineDocument {
    let duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    if let previous, self.wordSearch == wordSearch, self.duration == duration,
      Self.same(previous, reply) { return value }
    value = InlineDocument(reply: reply, wordSearch: wordSearch, duration: duration)
    previous = reply
    self.wordSearch = wordSearch
    self.duration = duration
    return value
  }

  private static func same(_ a: Reply.Content, _ b: Reply.Content) -> Bool {
    guard a.message == b.message, a.at_name_to_mid == b.at_name_to_mid, a.topics == b.topics,
      a.vote?.id?.number == b.vote?.id?.number, a.vote?.title == b.vote?.title,
      a.emote?.count == b.emote?.count, a.jump_url?.count == b.jump_url?.count else { return false }
    for (key, x) in a.emote ?? [:] {
      guard let y = b.emote?[key], x.url == y.url, x.meta?.alias == y.meta?.alias,
        x.meta?.size == y.meta?.size, x.jump_url == y.jump_url, x.jump_title == y.jump_title,
        x.webp_url == y.webp_url, x.gif_url == y.gif_url else { return false }
    }
    for (key, x) in a.jump_url ?? [:] {
      guard let y = b.jump_url?[key], x.title == y.title, x.app_url_schema == y.app_url_schema,
        x.extra?.isWordSearch == y.extra?.isWordSearch else { return false }
    }
    return true
  }
}

/// Equatable on what it targets (the seek closure is that player's own), so the comments under
/// a player are not all re-rendered whenever the page passes a fresh one down.
struct ReplyPlaybackTarget: Equatable {
  let duration: Double, seek: (Double) -> Void
  var model:PlayerModel?=nil
  nonisolated static func == (a: Self, b: Self) -> Bool { a.duration == b.duration && a.model === b.model }
}
private enum ReplyPlaybackKey: EnvironmentKey { static let defaultValue: ReplyPlaybackTarget? = nil }
extension EnvironmentValues {
  var replyPlayback: ReplyPlaybackTarget? {
    get { self[ReplyPlaybackKey.self] }
    set { self[ReplyPlaybackKey.self] = newValue }
  }
}

extension InlineDocument {
  init(reply: Reply.Content, wordSearch: Bool, duration: Double?) {
    let raw = reply.message as NSString, source = InlineDocument(text: reply.message)
    var candidates = [(NSRange, Int, RichNode)]()
    func add(_ key: String, _ node: RichNode, _ priority: Int, once: Bool = false) {
      let locations = source.ranges(key)
      for r in locations.prefix(once ? 1 : locations.count) { candidates.append((r, priority, node)) }
    }
    for (token, e) in reply.emote ?? [:] {
      guard let u = e.url.flatMap(GalleryPicture.source) ?? e.moving else { continue }
      let art = RichNode.Emote(name: e.meta?.alias.flatMap { $0.isEmpty ? nil : $0 } ?? token,
        url: u, size: e.meta?.size ?? 1, jump: e.jump_url, jumpTitle: e.jump_title, animation: e.moving)
      add(token, RichNode(text: token, emote: art), 0)
    }
    for (name, mid) in reply.at_name_to_mid ?? [:] where mid > 0 {
      add("@" + name, RichNode(text: "@" + name, target: .route(.creator(mid))), 1)
    }
    if let v = reply.vote, let id = v.id?.number, id > 0 {
      add("{vote:\(id)}", RichNode(text: "投票：" + (v.title ?? "查看投票"), target: .vote(id)), 2)
    }
    for (key, link) in reply.jump_url ?? [:] {
      let label = link.title.flatMap { $0.isEmpty ? nil : $0 } ?? key
      if link.extra?.isWordSearch == true {
        add(key, RichNode(text: wordSearch ? label : key, target: wordSearch ? .search(label) : nil), 3, once: true)
      } else {
        let route = SharedLink.parse(key) ?? link.app_url_schema.flatMap(SharedLink.parse)
        let target = route.map(RichNode.Target.route) ?? GalleryPicture.source(key).map(RichNode.Target.url)
        if let target { add(key, RichNode(text: label, target: target), 3, once: true) }
      }
    }
    for topic in reply.topics where !topic.isEmpty {
      let token = topic.hasPrefix("#") ? topic : "#" + topic + "#"
      add(token, RichNode(text: token, target: .search(topic.trimmingCharacters(in: CharacterSet(charactersIn: "#")))), 4)
    }
    let all = NSRange(location: 0, length: raw.length)
    if let detector = Self.replyWebDetector {
      for match in detector.matches(in: reply.message, range: all) {
        guard let u = match.url, let safe = GalleryPicture.source(u.absoluteString) else { continue }
        let value = raw.substring(with: match.range)
        let target = SharedLink.parse(value).map(RichNode.Target.route) ?? .url(safe)
        candidates.append((match.range, 5, RichNode(text: value, target: target)))
      }
    }
    if let duration, duration.isFinite, duration > 0 {
      for match in Self.replyTimePattern.matches(in: reply.message, range: all) {
        let value = raw.substring(with: match.range)
        let parts = value.replacingOccurrences(of: "：", with: ":").split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, parts.dropFirst().allSatisfy({ (0..<60).contains($0) }) else { continue }
        let seconds = parts.reduce(0) { $0 * 60 + $1 }
        if Double(seconds) <= duration { candidates.append((match.range, 6, RichNode(text: value, target: .timestamp(seconds)))) }
      }
    }
    candidates.sort {
      if $0.0.location != $1.0.location { return $0.0.location < $1.0.location }
      if $0.1 != $1.1 { return $0.1 < $1.1 }
      return $0.0.length > $1.0.length
    }
    var nodes = [RichNode](), start = 0
    for (range, _, node) in candidates where range.location >= start {
      if start < range.location { nodes.append(.init(text: raw.substring(with: NSRange(location: start, length: range.location - start)))) }
      nodes.append(node); start = NSMaxRange(range)
    }
    if start < raw.length { nodes.append(.init(text: raw.substring(from: start))) }
    self.init(nodes: nodes)
  }
  private static let replyTimePattern = try! NSRegularExpression(pattern: #"(?<![0-9:：])(?:[0-9]{1,3}[:：])?[0-9]{1,3}[:：][0-9]{2}(?![0-9:：])"#)
  private static let replyWebDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
}
