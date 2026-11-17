import Foundation

struct DanmakuStyle: Codable, Equatable, Sendable {
  var hideScroll = false, hideTop = false, hideBottom = false, hideSpecial = false
  var monochrome = false, showVIP = true, merge = false, fixedVelocity = false,
    convertFixed = false, dense = false
  var duration = 7.0, staticDuration = 4.0, lineHeight = 1.6, stroke = 1.5, fontWeight = 6,
    minimumWeight = 0
  var expressions = "", senders = ""
  static let key = "dm.layout.v1"
  init() {}
  static func decode(_ d: Data) -> Self {
    (try? JSONDecoder().decode(Self.self, from: d)) ?? Self()
  }
  func validate() throws {
    guard (1...50).contains(duration), (1...50).contains(staticDuration),
      (0.8...3).contains(lineHeight), (0...5).contains(stroke), (1...9).contains(fontWeight),
      (0...11).contains(minimumWeight), expressions.utf8.count <= 4096, senders.utf8.count <= 8192
    else { throw ServiceError("弹幕参数超出可用范围") }
    for line in expressions.split(whereSeparator: \.isNewline) {
      _ = try NSRegularExpression(pattern: String(line), options: .caseInsensitive)
    }
  }
  func save(_ d: UserDefaults = .standard) throws {
    try validate()
    d.set(try JSONEncoder().encode(self), forKey: Self.key)
  }
  func admits(_ b: Bullet) -> Bool {
    guard (b.weight ?? 0) >= minimumWeight else { return false }
    switch b.mode {
    case 4: return !hideBottom
    case 5: return !hideTop
    case 7: return !hideSpecial
    default: return !hideScroll
    }
  }
  static func senderHash(_ own: String) -> String {
    var crc = UInt32.max
    for byte in own.utf8 {
      crc ^= UInt32(byte)
      for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb8_8320) }
    }
    return String(crc ^ .max, radix: 16)
  }
  struct Visible: Sendable {
    var item: Bullet
    var repeats = 1
  }
  func visible(_ items: [Bullet], keywords: String, own: String?, cloud: CloudBulletMatcher = .init([])) -> [Visible] {
    let words = keywords.split(whereSeparator: \.isNewline).map(String.init)
    let patterns = expressions.split(whereSeparator: \.isNewline).compactMap {
      try? NSRegularExpression(pattern: String($0), options: .caseInsensitive)
    }
    let hidden = Set(
      senders.split(whereSeparator: { $0.isNewline || $0 == "," }).map {
        $0.trimmingCharacters(in: .whitespaces).lowercased()
      })
    struct Key: Hashable { let segment: Int, text: String }
    var seen: [Key: Int] = [:]
    var out: [Visible] = []
    for (offset, b) in items.enumerated() {
      if offset & 63 == 0 && Task.isCancelled { return [] }
      guard b.time.isFinite, b.time >= 0, b.time / 360 < Double(Int.max) else { continue }
      let mine = own != nil && b.sender == own
      let raw = b.wireText ?? b.text
      var group: Key?
      if !mine && merge && (b.special == nil || b.wireText != nil) {
        let key = Key(segment: Int(b.time / 360), text: raw)
        if let index = seen[key] {
          if index >= 0 { out[index].repeats += 1 }
          continue
        }
        // An upstream group retains its first member, including its moderation and display state.
        seen[key] = -1
        group = key
      }
      guard admits(b) else { continue }
      if !mine {
        if cloud.hides(text: raw, sender: b.sender) { continue }
        if let id = b.sender, hidden.contains(id.lowercased()) { continue }
        if words.contains(where: { raw.localizedStandardContains($0) })
          || patterns.contains(where: {
            $0.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil
          })
        { continue }
      }
      if let group { seen[group] = out.count }
      out.append(Visible(item: b))
    }
    return out
  }
}
