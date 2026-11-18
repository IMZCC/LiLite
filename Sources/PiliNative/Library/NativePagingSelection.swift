/// Settled selection with an outstanding SwiftUI binding acknowledgement. Metadata refreshes
/// carrying the old binding must not bounce a completed swipe back to its starting page.
struct NativePagingSelection {
  private(set) var count = 0
  private(set) var selected = 0
  private(set) var requested = 0
  private var external = 0
  private var pendingCommit: Int?
  private var overridden = false
  mutating func update(count: Int, page: Int, moving: Bool) {
    let count = max(0, count)
    let next = min(max(0, page), max(0, count - 1))
    let acknowledgement = pendingCommit == next
    if next != external || count != self.count {
      external = next
      requested = next
      pendingCommit = nil
      if moving && !acknowledgement { overridden = true }
    }
    self.count = count
    if pendingCommit == nil { requested = next }
  }
  mutating func applied() {
    selected = requested
    overridden = false
  }
  /// A tap can also reselect the original tab while a swipe is coasting away from it.
  mutating func request(_ page: Int) {
    requested = min(max(0, page), max(0, count - 1))
    pendingCommit = nil
    overridden = true
  }
  mutating func settle(at page: Int) -> Int? {
    selected = min(max(0, page), max(0, count - 1))
    guard !overridden else { return nil }
    requested = selected
    guard selected != external else { pendingCommit = nil; return nil }
    guard pendingCommit != selected else { return nil }
    pendingCommit = selected
    return selected
  }
  func canPublish(_ page: Int) -> Bool { pendingCommit == page && requested == page && !overridden }
}
