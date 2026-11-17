import Foundation

/// Mode 7 is a JSON array of numeric animation parameters, not executable content.
struct SpecialBullet: Equatable, Codable, Sendable {
  let text: String, duration: Double, x1: Double, y1: Double, x2: Double, y2: Double, fade1: Double,
    fade2: Double, angle: Double, tilt: Double, movement: Double, delay: Double, stroke: Bool,
    ease: Bool
  init?(_ raw: String) {
    guard raw.utf8.count < 65536,
      let a = Self.array(raw), a.count >= 5,
      let text = a[4] as? String, !text.isEmpty
    else { return nil }
    func n(_ i: Int) -> Double? {
      guard a.indices.contains(i) else { return nil }
      let v = (a[i] as? NSNumber)?.doubleValue ?? (a[i] as? String).flatMap(Double.init)
      return v.flatMap { $0.isFinite ? $0 : nil }
    }
    func position(_ i: Int, _ size: Double) -> Double? {
      guard let v = n(i), abs(v) <= 1_000_000 else { return nil }
      if v > 1 || ((a[i] as? String).map { !$0.contains(".") } ?? false) { return v / size }
      return v
    }
    guard let duration = n(3), duration > 0, duration <= 300 else { return nil }
    self.text = String(text.reversed().drop(while: { $0.isWhitespace }).reversed())
    self.duration = duration
    x1 = position(0, 1920) ?? position(7, 1920) ?? 0
    y1 = position(1, 1080) ?? position(8, 1080) ?? 0
    x2 = position(7, 1920) ?? x1
    y2 = position(8, 1080) ?? y1
    var alpha: [Double] = []
    if let s = a[2] as? String { alpha = s.split(separator: "-").compactMap { Double($0) } }
    let initial = alpha.first ?? n(2) ?? 1
    fade1 = initial.isFinite ? min(1, max(0, initial)) : 1
    let final = alpha.last ?? fade1
    fade2 = final.isFinite ? min(1, max(0, final)) : fade1
    angle = (n(5) ?? 0).truncatingRemainder(dividingBy: 360)
    tilt = (n(6) ?? 0).truncatingRemainder(dividingBy: 360)
    movement = max(0, (n(9) ?? duration * 1000) / 1000)
    delay = max(0, (n(10) ?? 0) / 1000)
    stroke = n(11) == 1
    ease = n(13) == 1
  }
  private static func array(_ source: String) -> [Any]? {
    let bytes = Data(source.utf8)
    if let rows = (try? JSONSerialization.jsonObject(with: bytes)) as? [Any] { return rows }
    var clean = Data(), quoted = false, escaped = false
    for b in bytes {
      if quoted && !escaped && (b == 10 || b == 13) {
        clean.append(92); clean.append(b == 10 ? 110 : 114)
        continue
      }
      clean.append(b)
      if !escaped && b == 34 { quoted.toggle() }
      escaped = quoted && !escaped && b == 92
    }
    return (try? JSONSerialization.jsonObject(with: clean)) as? [Any]
  }
  private static func cubic(_ x: Double) -> Double {
    if x <= 0 || x >= 1 { return x }
    func axis(_ t: Double, _ a: Double, _ b: Double) -> Double {
      let u = 1 - t
      return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
    }
    var low = 0.0, high = 1.0
    for _ in 0..<22 {
      let t = (low + high) / 2
      if axis(t, 0.55, 0.675) < x { low = t } else { high = t }
    }
    return axis((low + high) / 2, 0.055, 0.19)
  }
  func frame(_ elapsed: Double) -> (x: Double, y: Double, opacity: Double) {
    let q = elapsed <= delay ? 0 : movement > 0 ? min(1, (elapsed - delay) / movement) : 1
    let t = ease ? Self.cubic(q) : q
    let fade = min(1, max(0, elapsed / duration))
    return (x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, fade1 + (fade2 - fade1) * fade)
  }
}
