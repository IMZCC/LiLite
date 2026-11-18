import Foundation

/// Layout of a player page, after the original client's video page:
/// - `stacked`: player on top, tabs under it (phones, folded Duo, narrow iPad windows);
/// - `side`: landscape, player and intro on the left, comments and episodes on the right;
/// - `square`: nearly square large windows (unfolded Duo held sideways in Split View, 13" iPad
///   portrait): player across the top, intro / comments / episodes as columns below.
enum PlayerPageLayout: Equatable {
  /// `tabletop`: an iPhone Duo stood partly folded with the hinge across the screen — the
  /// picture above the fold, tabs below it, nothing laid across the division.
  case stacked, side, square, tabletop
  static func isLargeWindow(_ size: CGSize) -> Bool { min(size.width, size.height) >= 600 }
  static func partition(width: CGFloat, height: CGFloat, fold: CGRect?) -> (mode: Self, edge: CGFloat, gap: CGFloat)? {
    guard let rect = fold else { return nil }
    if rect.width >= width * 0.8, rect.minY >= 120, rect.maxY <= height - 120 {
      return (.tabletop, rect.minY, rect.height)
    }
    if rect.height >= height * 0.8, rect.minX >= width * 0.3, rect.maxX <= width * 0.8 {
      return (.side, rect.minX, rect.width)
    }
    return nil
  }
  /// The original's thresholds: landscape once width / height ≥ 1.2; "almost square" when a
  /// full-width 16:9 player would still leave 60% of the height.
  static func resolve(width: CGFloat, height: CGFloat, horizontal: Bool) -> Self {
    guard width > 0, height > 0 else { return .stacked }
    if width / height >= 1.2, width >= 540 { return horizontal ? .side : .stacked }
    guard horizontal, width >= 600 else { return .stacked }
    return width / (16.0 / 9) >= 0.4 * height ? .square : .stacked
  }
  /// Player width in the side layout (the original's `_childWhenDisabledLandscapeInner`).
  static func sideWidth(width: CGFloat, height: CGFloat) -> CGFloat {
    var w = min(0.7, max(0.5, height / width * 1.08)) * width
    if width >= 560 { w = width - min(425, max(280, width - w)) }
    return w
  }
}
