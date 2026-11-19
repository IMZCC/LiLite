import Foundation

/// A reference, so arming it at every touch-down and clearing it when scrolling stops never
/// invalidates the feed: as a value in `@State` each write re-evaluated every visible card.
/// It also holds the channel's on-screen flag and its running page load for the same reason.
@MainActor final class FeedScrollPaging {
  private var canLoad = false
  /// Whether the channel is the one on screen (only it pages automatically).
  var active = true
  private var load: Task<Void, Never>?

  /// Within a screen and a half of the end: the next page is requested while there is still
  /// plenty to read, so it is in place before the reader gets there (no spinner, no wait).
  nonisolated static func nearEnd(visible: CGRect, contentHeight: CGFloat) -> Bool {
    guard visible.height > 0, visible.minY > 0, contentHeight > visible.height else { return false }
    return contentHeight - visible.maxY <= visible.height * 1.5
  }

  func beginDrag() { canLoad = true }
  func endDrag() { canLoad = false }

  // One drag (including its deceleration) can request one page. Appending its
  // results, estimating grid heights or resizing the viewport cannot arm another.
  func takePage(nearEnd: Bool) -> Bool {
    guard nearEnd, canLoad else { return false }
    canLoad = false
    return true
  }

  func startLoad(_ work: @escaping @MainActor () async -> Void) {
    load?.cancel()
    load = Task { await work() }
  }
  func cancelLoad() {
    load?.cancel()
    load = nil
  }
}
