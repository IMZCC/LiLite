import Foundation

struct SubtitleCue: Codable, Equatable, Sendable { let from: Double, to: Double, content: String }
enum SubtitleFileFormat: String, CaseIterable, Identifiable, Sendable {
  case json, bcc, vtt, srt, ass
  var id: Self { self }
  static let exports: [Self] = [.vtt, .srt, .json]
  var label: String { self == .vtt ? "WebVTT" : rawValue.uppercased() }
}
struct SubtitleDocument: Sendable {
  struct File: Codable { let body: [SubtitleCue] }
  static let maxBytes = 8 * 1024 * 1024, maxRows = 50000
  let cues: [SubtitleCue], originalJSON: Data?, assPayload: Data?
  init(cues: [SubtitleCue], originalJSON: Data? = nil, assPayload: Data? = nil) throws {
    guard cues.count <= Self.maxRows else { throw ServiceError("字幕条数过多") }
    var checked = [(index: Int, cue: SubtitleCue)]()
    checked.reserveCapacity(cues.count)
    for (i, v) in cues.enumerated() {
      guard v.from.isFinite, v.to.isFinite, v.from >= 0, v.to > v.from, v.to <= 31_536_000,
        v.content.utf8.count <= 64 * 1024
      else { throw ServiceError("字幕时间或内容无效") }
      if !v.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        checked.append((i, v))
      }
    }
    checked.sort { a, b in
      if a.cue.from == b.cue.from { return a.index < b.index }
      return a.cue.from < b.cue.from
    }
    self.cues = checked.map(\.cue)
    self.originalJSON = originalJSON
    self.assPayload = assPayload
  }
  init(_ data: Data, format: SubtitleFileFormat) throws {
    guard !data.isEmpty, data.count <= Self.maxBytes else { throw ServiceError("字幕文件为空或超过 8 MB") }
    if format == .json || format == .bcc {
      let f = try JSONDecoder().decode(File.self, from: data)
      try self.init(cues: f.body, originalJSON: data)
      return
    }
    let text: String?
    if data.starts(with: [0xff, 0xfe]) {
      text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
    } else if data.starts(with: [0xfe, 0xff]) {
      text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
    } else {
      text = String(
        data: data.starts(with: [0xef, 0xbb, 0xbf]) ? data.dropFirst(3) : data[...], encoding: .utf8
      )
    }
    guard let text else { throw ServiceError("字幕文件编码不受支持") }
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
      of: "\r", with: "\n"
    ).components(separatedBy: "\n")
    let result = try format == .ass ? Self.ass(lines) : Self.timed(lines, vtt: format == .vtt)
    let ass = format == .ass ? Data(text.utf8) : nil
    guard
      !result.isEmpty
        || (ass != nil
          && lines.contains(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("dialogue:")
          }))
    else { throw ServiceError("文件中没有有效字幕") }
    try self.init(cues: result, assPayload: ass)
  }
  static func instant(_ input: String) -> Double? {
    let s = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
      of: ",", with: ".")
    let p = s.split(separator: ":", omittingEmptySubsequences: false)
    guard (2...3).contains(p.count) else { return nil }
    func number(_ s: Substring) -> Int? {
      !s.isEmpty && s.count <= 8 && s.utf8.allSatisfy { (48...57).contains($0) } ? Int(s) : nil
    }
    let sec = p.last!.split(separator: ".", omittingEmptySubsequences: false)
    guard sec.count <= 2, let t = number(sec[0]), t < 60, let m = number(p[p.count - 2]), m < 60
    else { return nil }
    var ms = 0.0
    if sec.count == 2 {
      guard sec[1].count <= 3, let n = number(sec[1]) else { return nil }
      ms = Double(n) / pow(10, Double(sec[1].count))
    }
    let h = p.count == 3 ? number(p[0]) : 0
    guard let h, h <= 8760 else { return nil }
    return Double(h * 3600 + m * 60 + t) + ms
  }
  private static func timed(_ lines: [String], vtt: Bool) throws -> [SubtitleCue] {
    var list = [SubtitleCue]()
    var block = [String]()
    if vtt {
      guard lines.first?.hasPrefix("WEBVTT") == true else { throw ServiceError("无效的 WebVTT 字幕") }
    }
    func consume() throws {
      defer { block.removeAll(keepingCapacity: true) }
      guard !block.isEmpty else { return }
      let start = block[0]
      if vtt
        && (start == "WEBVTT" || start.hasPrefix("WEBVTT ") || start == "STYLE" || start == "REGION"
          || start == "NOTE" || start.hasPrefix("NOTE ") || start.hasPrefix("NOTE\t"))
      {
        return
      }
      guard let i = block.prefix(2).firstIndex(where: { $0.contains("-->") }) else { return }
      let edges = block[i].components(separatedBy: "-->")
      guard edges.count == 2, let a = instant(edges[0]),
        let end = edges[1].split(whereSeparator: { $0.isWhitespace }).first,
        let b = instant(String(end)), a < b
      else { throw ServiceError("字幕时间轴无效") }
      let raw = block.dropFirst(i + 1).joined(separator: "\n")
      let body = Self.markup(raw)
      guard list.count < Self.maxRows else { throw ServiceError("字幕条数过多") }
      list.append(.init(from: a, to: b, content: body))
    }
    for line in lines {
      if line.trimmingCharacters(in: .whitespaces).isEmpty {
        try consume()
      } else {
        block.append(line)
      }
    }
    try consume()
    return list
  }
  private static func markup(_ text: String) -> String {
    // Only remove caption markup / embedded timestamps. Literal mathematical angle brackets remain.
    text.replacingOccurrences(
      of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive]
    )
    .replacingOccurrences(
      of: #"</?(?:[biucv]|ruby|rt|lang|font)(?:[.\s][^<>\n]{0,200})?>|<[\d:.]+>"#, with: "",
      options: [.regularExpression, .caseInsensitive]
    )
    .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
    .replacingOccurrences(of: "&lrm;", with: "\u{200e}").replacingOccurrences(
      of: "&rlm;", with: "\u{200f}"
    ).replacingOccurrences(of: "&amp;", with: "&")
  }
  private static func ass(_ lines: [String]) throws -> [SubtitleCue] {
    var events = false
    var fields = [
      "layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text",
    ]
    var rows = [SubtitleCue]()
    for raw in lines {
      let l = raw.trimmingCharacters(in: .whitespaces)
      if l.hasPrefix("[") {
        events = l.lowercased() == "[events]"
        continue
      }
      guard events, let pos = l.firstIndex(of: ":") else { continue }
      let tag = l[..<pos].lowercased()
      let values = l[l.index(after: pos)...]
      if tag == "format" {
        fields = values.split(separator: ",").map {
          $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        continue
      }
      guard tag == "dialogue", fields.count >= 3, fields.count < 64, fields.last == "text",
        let a = fields.firstIndex(of: "start"), let b = fields.firstIndex(of: "end")
      else { continue }
      let p = values.split(
        separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false)
      guard p.count == fields.count, let start = instant(String(p[a])),
        let end = instant(String(p[b])), end > start
      else { throw ServiceError("ASS 字幕时间轴无效") }
      let text = plainASS(String(p.last!))
      if !text.isEmpty {
        guard rows.count < Self.maxRows else { throw ServiceError("字幕条数过多") }
        rows.append(.init(from: start, to: end, content: text))
      }
    }
    return rows
  }
  private static func plainASS(_ s: String) -> String {
    var out = ""
    var drawing = false
    var i = s.startIndex
    while i < s.endIndex {
      if s[i] == "{" {
        guard let end = s[i...].firstIndex(of: "}") else {
          if !drawing { out += s[i...] }
          break
        }
        let commands = s[s.index(after: i)..<end].split(separator: "\\")
        for token in commands where token.first == "p" {
          let value = token.dropFirst().prefix(while: { $0.isNumber })
          if let n = Int(value) { drawing = n > 0 }
        }
        i = s.index(after: end)
        continue
      }
      if drawing {
        i = s.index(after: i)
        continue
      }
      if s[i] == "\\" {
        let j = s.index(after: i)
        if j < s.endIndex {
          let c = s[j]
          if c == "N" || c == "n" || c == "h" {
            out += c == "h" ? "\u{00a0}" : "\n"
            i = s.index(after: j)
            continue
          }
        }
      }
      out.append(s[i])
      i = s.index(after: i)
    }
    return out
  }
  func bytes(_ format: SubtitleFileFormat) throws -> Data {
    if format == .json || format == .bcc {
      return try originalJSON ?? JSONEncoder().encode(File(body: cues))
    }
    guard format == .srt || format == .vtt else { throw ServiceError("不支持这个导出格式") }
    func stamp(_ t: Double) -> String {
      let v = Int64((t * 1000).rounded())
      return String(
        format: "%02lld:%02lld:%02lld%@%03lld", v / 3_600_000, v / 60000 % 60, v / 1000 % 60,
        format == .vtt ? "." : ",", v % 1000)
    }
    var s = format == .vtt ? "WEBVTT\n\n" : ""
    for (n, v) in cues.enumerated() {
      let text = v.content.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
        of: "&", with: "&amp;"
      ).replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
      if format == .srt { s += "\(n+1)\n" }
      s += "\(stamp(v.from)) --> \(stamp(v.to))\n\(text)\n\n"
    }
    return Data(s.utf8)
  }
}

/// Non-overlapping intervals from one or two independent tracks. Each lookup is logarithmic.
/// Keep indexes instead of copying long strings into repeated generated overlap intervals.
struct SubtitleTimeline: Sendable {
  private struct Node: Sendable { let start: Double, end: Double, ids: [Int] }
  private let text: [String], spans: [Node]
  init(_ first: [SubtitleCue] = [], _ second: [SubtitleCue] = []) {
    let all = first + second
    text = all.map(\.content)
    if all.isEmpty {
      spans = []
      return
    }
    var events = [(time: Double, id: Int, starts: Bool)]()
    events.reserveCapacity(all.count * 2)
    for (i, c) in all.enumerated() where c.from.isFinite && c.to.isFinite && c.to > c.from {
      if i & 63 == 0 && Task.isCancelled { spans = []; return }
      events.append((c.from, i, true))
      events.append((c.to, i, false))
    }
    events.sort { $0.time == $1.time ? (!$0.starts && $1.starts) : $0.time < $1.time }
    // Fenwick tree gives the first 12 active cues in document order even for a dense ASS.
    var tree = [Int](repeating: 0, count: all.count + 1)
    var count = 0
    var active = [Int]()
    var result = [Node]()
    var at = 0
    var start = events.first?.time ?? 0
    func update(_ id: Int, _ delta: Int) {
      var x = id + 1
      while x < tree.count {
        tree[x] += delta
        x += x & -x
      }
    }
    func select(_ k: Int) -> Int {
      var x = 0
      var b = 1
      var rank = k
      while b < tree.count { b <<= 1 }
      while b > 0 {
        let v = x + b
        if v < tree.count && tree[v] < rank {
          x = v
          rank -= tree[v]
        }
        b >>= 1
      }
      return x
    }
    while at < events.count {
      if Task.isCancelled { spans = []; return }
      let t = events[at].time
      if t > start, !active.isEmpty { result.append(Node(start: start, end: t, ids: active)) }
      while at < events.count, events[at].time == t {
        let e = events[at]
        let d = e.starts ? 1 : -1
        update(e.id, d)
        count += d
        at += 1
      }
      active = count > 0 ? (1...min(12, count)).map(select) : []
      start = t
    }
    spans = result
  }
  static func prepare(_ first: [SubtitleCue], _ second: [SubtitleCue] = []) async throws -> Self {
    let work = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let value = Self(first, second)
      try Task.checkCancellation()
      return value
    }
    return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
  }
  /// A small identity for cue boundaries, so the control clock need not rebuild subtitle strings.
  var isEmpty: Bool { spans.isEmpty }
  func interval(at t: Double) -> Int? {
    guard t.isFinite else { return nil }
    var l = 0
    var r = spans.count
    while l < r {
      let m = (l + r) / 2
      if spans[m].start <= t { l = m + 1 } else { r = m }
    }
    guard l > 0, spans[l - 1].end > t else { return nil }
    return l - 1
  }
  func active(at t: Double) -> String? {
    guard let index = interval(at: t) else { return nil }
    var seen = Set<String>()
    let parts = spans[index].ids.compactMap { i -> String? in
      let s = text[i]
      return seen.insert(s).inserted ? s : nil
    }
    return parts.isEmpty ? nil : parts.joined(separator: "\n")
  }
}
