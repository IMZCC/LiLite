import Foundation

enum BulletTrackFrame {
  static func timeLink(_ text: String, duration: Double) -> Double? {
    guard
      let range = text.range(of: #"(?:\d+[:：])?\d+[:：][0-5]?\d(?!\d)"#, options: .regularExpression)
    else { return nil }
    let parts = text[range].split(whereSeparator: { $0 == ":" || $0 == "：" })
    var sum = 0.0
    for part in parts {
      guard let n = Double(part), n.isFinite else { return nil }
      sum = sum * 60 + n
    }
    return sum > 0 && sum < duration ? sum : nil
  }
  static func rect(
    mode: Int, lane: Int, width: CGFloat, point: CGFloat, step: CGFloat, elapsed: Double,
    duration: Double, size: CGSize
  ) -> CGRect? {
    guard duration > 0, elapsed >= 0, elapsed <= duration else { return nil }
    let k = elapsed / duration
    let x: CGFloat
    switch mode {
    case 4, 5: x = (size.width - width) / 2
    case 6: x = -width + (size.width + width) * k
    default: x = size.width - (size.width + width) * k
    }
    let y = CGFloat(lane) * step
    return CGRect(x: x, y: y, width: width, height: point * 1.3)
  }
}

// Track indices are physical rows counted from the top, including static bottom comments.
struct BulletLanes {
  struct Slot: Equatable { let mode: Int, lane: Int, duration: Double }
  private var fixed: [Double], entered: [Double], gone: [Double]
  private let width: Double
  static func count(height: Double, area: Double, step: Double) -> Int {
    guard height.isFinite, area.isFinite, step.isFinite, height > 0, step > 0, (0...1).contains(area) else { return 0 }
    return max(0, Int(min(4096, floor(height * area / step))) - (area == 1 ? 1 : 0))
  }
  init(count: Int, width: Double) {
    self.width = width
    fixed = .init(repeating: -.infinity, count: min(4096, max(0, count)))
    entered = fixed; gone = fixed
  }
  mutating func place(mode: Int, at time: Double, width w: Double, own: Bool, style: DanmakuStyle, seed: UInt64) -> Slot? {
    guard !fixed.isEmpty, time.isFinite, w.isFinite, w >= 0, width.isFinite, width > 0 else { return nil }
    let isFixed = mode == 4 || mode == 5
    if isFixed {
      let fits = !style.convertFixed || w <= width
      if fits {
        let ix = mode == 4 ? fixed.lastIndex(where: { $0 <= time }) : fixed.firstIndex(where: { $0 <= time })
        if let ix {
          fixed[ix] = time + style.staticDuration
          return Slot(mode: mode, lane: ix, duration: style.staticDuration)
        }
      }
      guard (style.convertFixed && !style.hideScroll) || (own && fits) else { return nil }
    }
    let duration = style.duration * (style.fixedVelocity ? (width + w) / width : 1)
    let untilLeft = duration * width / (width + w)
    var ix = entered.indices.first { entered[$0] <= time && (style.fixedVelocity || gone[$0] <= time + untilLeft) }
    if ix == nil && own { ix = 0 }
    if ix == nil && style.dense { ix = Int(seed % UInt64(entered.count)) }
    guard let ix else { return nil }
    entered[ix] = time + duration * w / (width + w)
    gone[ix] = time + duration
    return Slot(mode: 1, lane: ix, duration: duration)
  }
}
