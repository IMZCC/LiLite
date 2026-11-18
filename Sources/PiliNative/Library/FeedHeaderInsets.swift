import Foundation

/// Insets are local to the view being laid out. Window coordinates have already
/// been converted by UIKit, and SwiftUI supplies reserved regions in header coordinates.
struct FeedHeaderInsets: Equatable {
  var top: CGFloat = 0, leading: CGFloat = 0, trailing: CGFloat = 0

  static func window(bounds: CGRect, safe: CGRect, rightToLeft: Bool) -> Self {
    let left = max(0, safe.minX - bounds.minX), right = max(0, bounds.maxX - safe.maxX)
    return Self(top: max(0, safe.minY - bounds.minY),
      leading: rightToLeft ? right : left, trailing: rightToLeft ? left : right)
  }

  static func avoiding(width: CGFloat, height: CGFloat, regions: [CGRect]) -> Self {
    guard width > 0, height > 0, !regions.isEmpty else { return Self() }
    var top: CGFloat = 0
    for r in regions.sorted(by: { $0.minY < $1.minY })
      where r.minX <= 0 && r.maxX >= width && r.maxY > top && r.minY < top + height {
      top = r.maxY
    }
    let band = CGRect(x: 0, y: top, width: width, height: height)
    let blocked = regions.map { $0.intersection(band) }.filter { !$0.isEmpty }
      .sorted { $0.minX < $1.minX }
    var start: CGFloat = 0, bestStart: CGFloat = 0, bestWidth: CGFloat = 0
    for r in blocked {
      if r.minX - start > bestWidth { bestStart = start; bestWidth = r.minX - start }
      start = max(start, r.maxX)
    }
    if width - start >= bestWidth { bestStart = start; bestWidth = width - start }
    guard bestWidth > 0 else { return Self(top: top) }
    return Self(top: top, leading: bestStart, trailing: width - bestStart - bestWidth)
  }
}
