import Foundation

/// Insets are local to the view being laid out. Window coordinates have already
/// been converted by UIKit, and SwiftUI supplies reserved regions in header coordinates.
struct FeedHeaderInsets: Equatable {
  var top: CGFloat = 0, leading: CGFloat = 0, trailing: CGFloat = 0
  /// A hinge standing across the header (an iPhone Duo partly folded like a book), from its
  /// leading to its trailing edge in the header's own coordinates (after `leading`). The header
  /// is then laid out on both sides of it instead of squeezed into the wider one.
  var fold: Range<CGFloat>?
  /// The header's width these were worked out for.
  var width: CGFloat = 0

  /// Nothing to keep clear of.
  var isEmpty: Bool { top == 0 && leading == 0 && trailing == 0 && fold == nil }

  static func window(bounds: CGRect, safe: CGRect, rightToLeft: Bool) -> Self {
    let left = max(0, safe.minX - bounds.minX), right = max(0, bounds.maxX - safe.maxX)
    return Self(top: max(0, safe.minY - bounds.minY),
      leading: rightToLeft ? right : left, trailing: rightToLeft ? left : right)
  }

  /// `divisions` are the device's folds, `occlusions` what covers the screen (a camera). A fold
  /// running top to bottom through the middle of the header splits it; any other region is
  /// kept clear of.
  static func avoiding(width: CGFloat, height: CGFloat, divisions: [CGRect], occlusions: [CGRect]) -> Self {
    var hinge: CGRect?
    var others = occlusions
    for r in divisions {
      if hinge == nil, r.minY <= 0, r.maxY >= height, r.minX >= width * 0.25, r.maxX <= width * 0.75 {
        hinge = r
      } else {
        others.append(r)
      }
    }
    var result = avoiding(width: width, height: height, regions: others)
    guard let hinge else { return result }
    // The kept span has to reach across the hinge for the halves to sit on either side of it;
    // otherwise the hinge is kept clear of like anything else.
    let start = result.leading, end = width - result.trailing
    guard hinge.minX > start, hinge.maxX < end else {
      return avoiding(width: width, height: height, regions: others + [hinge])
    }
    result.fold = (hinge.minX - start)..<(hinge.maxX - start)
    return result
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
