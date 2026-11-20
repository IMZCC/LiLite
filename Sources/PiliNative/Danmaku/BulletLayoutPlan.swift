import Foundation

extension Array where Element == Bullet {
  func partitionIndex(after time: Double) -> Int {
    var lo = 0, hi = count
    while lo < hi {
      let mid = lo + (hi - lo) / 2
      if self[mid].time <= time { lo = mid + 1 } else { hi = mid }
    }
    return lo
  }
}

/// Per-block latest end times let a seek skip expired rows, even when an early long-lived
/// comment is still visible. The immutable tree is built with the layout, off the UI thread.
struct BulletWindowIndex: Sendable {
  private static let block = 32
  private let count: Int, base: Int, ends: [Double]
  init(count: Int, end: (Int) -> Double) throws {
    self.count = count
    var base = 1
    while base < (count + Self.block - 1) / Self.block { base *= 2 }
    self.base = base
    var ends = [Double](repeating: -.infinity, count: base * 2)
    for i in 0..<count {
      if i & 1023 == 0 { try Task.checkCancellation() }
      let leaf = base + i / Self.block
      ends[leaf] = max(ends[leaf], end(i))
    }
    for i in (1..<base).reversed() { ends[i] = max(ends[2*i], ends[2*i+1]) }
    self.ends = ends
  }
  func window(now: Double, ahead: Double, limit: Int, start: (Int) -> Double, end: (Int) -> Double) -> [Int] {
    guard count > 0, now.isFinite, limit > 0 else { return [] }
    var lo = 0, hi = count
    while lo < hi {
      let m = lo + (hi - lo) / 2
      if start(m) <= now { lo = m + 1 } else { hi = m }
    }
    let split = lo
    var result = [Int]()
    func visit(_ node: Int, _ first: Int, _ blocks: Int) {
      guard first * Self.block < split, ends[node] > now, result.count < limit else { return }
      if blocks == 1 {
        for i in (first * Self.block..<min(split, (first + 1) * Self.block)).reversed() {
          if end(i) > now { result.append(i); if result.count == limit { break } }
        }
      } else {
        let half = blocks / 2
        visit(node * 2 + 1, first + half, half)
        visit(node * 2, first, half)
      }
    }
    visit(1, 0, base)
    result.reverse()
    var i = split
    while i < count, result.count < limit, start(i) <= now + ahead { result.append(i); i += 1 }
    return result
  }
}

/// A segment is prepared once away from the view actor; animation only selects visible rows.
struct BulletLayoutPlan: Sendable {
  struct Placement: Sendable {
    let bullet: Bullet
    let mode: Int, repeats: Int, mine: Bool, lane: Int
    let width: CGFloat, duration: Double
  }
  let rows: [Placement], special: [Bullet]
  private let rowIndex: BulletWindowIndex, effectIndex: BulletWindowIndex
  func regular(at time: Double, ahead: Double = 0, limit: Int = 96) -> [Int] {
    rowIndex.window(now: time, ahead: ahead, limit: limit, start: { rows[$0].bullet.time },
      end: { rows[$0].bullet.time + rows[$0].duration })
  }
  func effects(at time: Double, ahead: Double = 0, limit: Int = 24) -> [Int] {
    effectIndex.window(now: time, ahead: ahead, limit: limit, start: { special[$0].time },
      end: { special[$0].time + (special[$0].special?.duration ?? 0) })
  }
  static func prepare(
    _ items: [Bullet], style: DanmakuStyle, keywords: String, own: String?,
    cloud: CloudBulletMatcher, size: CGSize, area: Double, point: Double,
    measure: (String, Bool) -> Double
  ) throws -> Self {
    try Task.checkCancellation()
    var lanes = BulletLanes(
      count: BulletLanes.count(height: size.height, area: area, step: point * style.lineHeight),
      width: max(1, size.width))
    var rows = [Placement](), effects = [Bullet]()
    let visible = style.visible(items, keywords: keywords, own: own, cloud: cloud)
    try Task.checkCancellation()
    rows.reserveCapacity(visible.count)
    // Repeated comments share a measured run as well as their cached raster.
    struct Measured: Hashable { let text: String, badge: Bool }
    var widths = [Measured: Double]()
    func width(_ text: String, badge: Bool) -> Double {
      let key = Measured(text: text, badge: badge)
      if let hit = widths[key] { return hit }
      let result = measure(text, badge)
      widths[key] = result
      return result
    }
    for (offset, entry) in visible.enumerated() {
      if offset & 63 == 0 { try Task.checkCancellation() }
      let bullet = entry.item
      if bullet.special != nil { effects.append(bullet); continue }
      let mine = own != nil && own == bullet.sender
      let prefix = entry.repeats > 1 ? "(\(entry.repeats))" : ""
      let w = ceil(width(bullet.text, badge: false) + width(prefix, badge: true) + style.stroke + (mine ? 4 : 0))
      let seed = UInt64(bitPattern: bullet.entryID ?? Int64(rows.count)) &* 11400714819323198485
      guard let slot = lanes.place(mode: bullet.mode, at: bullet.time, width: w, own: mine, style: style, seed: seed) else { continue }
      rows.append(.init(bullet: bullet, mode: slot.mode, repeats: entry.repeats, mine: mine, lane: slot.lane, width: w, duration: slot.duration))
    }
    try Task.checkCancellation()
    return try .init(rows: rows, special: effects,
      rowIndex: BulletWindowIndex(count: rows.count) { rows[$0].bullet.time + rows[$0].duration },
      effectIndex: BulletWindowIndex(count: effects.count) { effects[$0].time + (effects[$0].special?.duration ?? 0) })
  }
}
