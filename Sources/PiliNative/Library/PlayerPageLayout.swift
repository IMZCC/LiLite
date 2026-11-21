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
    // A large window only just short of 1.2 (an open iPhone Duo, whose status area is counted in
    // the height) is still laid out side by side rather than as a phone.
    let landscape = width / height >= 1.2 || (horizontal && width >= 800 && width / height >= 1.1)
    if landscape, width >= 540 { return horizontal ? .side : .stacked }
    guard horizontal, width >= 600 else { return .stacked }
    return width / (16.0 / 9) >= 0.4 * height ? .square : .stacked
  }
  /// Where a video page will put its player, worked out from the page's size alone, before the
  /// page has been built: the first landing of 一镜到底 on a window of a size it has not opened a
  /// page in yet (an iPad, an unfolded or half-open Duo), so the card's picture flies straight
  /// to the player instead of to a full-width strip and then bending over. The same rules as
  /// `PlaybackPanels.plan` for a landscape picture. `fold` and the result are in the page's
  /// coordinates; `topInset` is the strip the page keeps above the player.
  static func expectedPlayer(page: CGSize, topInset: CGFloat, bottomInset: CGFloat, fold: CGRect?,
    horizontal: Bool) -> CGRect {
    let width = page.width, height = max(1, page.height - topInset - bottomInset)
    let full = height + topInset
    var mode = resolve(width: width, height: full, horizontal: horizontal)
    // `plan` gets the fold in its own space, which starts under the top strip.
    let partition = partition(width: width, height: height, fold: fold?.offsetBy(dx: 0, dy: -topInset))
    if let partition { mode = partition.mode }
    let ratio: CGFloat = 16.0 / 9
    let usable = max(1, height - topInset)
    let side = mode == .side
    let player = side
      ? (partition?.edge ?? max(130, min(sideWidth(width: width, height: full), usable * ratio)))
      : width
    let cap: CGFloat
    switch mode {
    case .side: cap = usable
    case .square: cap = full / 2.5
    case .tabletop: cap = max(1, partition?.edge ?? usable)
    case .stacked: cap = usable * 0.6
    }
    let tall = mode == .tabletop ? cap : max(1, min(player / ratio, cap))
    return CGRect(x: 0, y: topInset, width: player, height: tall)
  }
  /// Player width in the side layout (the original's `_childWhenDisabledLandscapeInner`).
  static func sideWidth(width: CGFloat, height: CGFloat) -> CGFloat {
    var w = min(0.7, max(0.5, height / width * 1.08)) * width
    // The column beside the player keeps room for its tabs and the bullet field (320 pt).
    if width >= 560 { w = width - min(425, max(320, width - w)) }
    return w
  }
}
