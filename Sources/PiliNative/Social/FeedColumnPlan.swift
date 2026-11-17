import Foundation

/// All pages share one set of column bottoms. A hidden/folded card occupies no space.
struct FeedColumnPlan {
  let width: CGFloat
  let height: CGFloat
  let frames: [CGRect]
  private let lanes: [[Int]]

  /// Each lane is ordered vertically, so scrolling only searches rows around the viewport.
  func visibleIndices(from lower: CGFloat, through upper: CGFloat) -> [Int] {
    var result: [Int] = []
    for lane in lanes {
      var lo = 0
      var hi = lane.count
      while lo < hi {
        let mid = lo + (hi - lo) / 2
        if frames[lane[mid]].maxY < lower { lo = mid + 1 } else { hi = mid }
      }
      while lo < lane.count, frames[lane[lo]].minY <= upper {
        result.append(lane[lo])
        lo += 1
      }
    }
    return result.sorted()
  }

  static func columns(width: CGFloat, cardWidth: CGFloat, largeText: Bool) -> Int {
    guard width.isFinite, width > 0, cardWidth.isFinite, !largeText else { return 1 }
    return Int(max(1, min(16, ceil(width / (max(150, min(500, cardWidth)) * 2 + 4)))))
  }

  init(width available: CGFloat, columns: Int, heights: [CGFloat], spacing: CGFloat = 4) {
    let n = max(1, min(16, columns))
    let gap = spacing.isFinite ? max(0, spacing) : 4
    let w = max(1, ((available.isFinite ? available : 1) - CGFloat(n - 1) * gap) / CGFloat(n))
    self.width = w
    var bottoms = Array(repeating: CGFloat.zero, count: n)
    var frames: [CGRect] = []
    var lanes = Array(repeating: [Int](), count: n)
    frames.reserveCapacity(heights.count)
    for h in heights {
      var column = 0
      for c in 1..<n where bottoms[c] < bottoms[column] { column = c }
      let height = h.isFinite ? max(0, h) : 0
      lanes[column].append(frames.count)
      frames.append(
        CGRect(x: CGFloat(column) * (w + gap), y: bottoms[column], width: w, height: height))
      if height > 0 { bottoms[column] += height + gap }
    }
    self.frames = frames
    self.lanes = lanes
    self.height = max(0, (bottoms.max() ?? 0) - gap)
  }
}
