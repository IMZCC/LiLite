import Foundation

struct FeedScrollPaging {
  private var canLoad = false

  static func nearEnd(visible: CGRect, contentHeight: CGFloat) -> Bool {
    guard visible.height > 0, visible.minY > 0, contentHeight > visible.height else { return false }
    return contentHeight - visible.maxY <= min(160, visible.height / 4)
  }

  mutating func beginDrag() { canLoad = true }
  mutating func endDrag() { canLoad = false }

  // One drag (including its deceleration) can request one page. Appending its
  // results, estimating grid heights or resizing the viewport cannot arm another.
  mutating func takePage(nearEnd: Bool) -> Bool {
    guard nearEnd, canLoad else { return false }
    canLoad = false
    return true
  }
}
