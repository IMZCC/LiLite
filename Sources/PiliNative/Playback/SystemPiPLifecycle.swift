/// AVKit may end PiP because it failed, because our view handed off its player,
/// because the user restored it, or because the background window was closed.
struct SystemPiPLifecycle {
  private(set) var started = false
  private(set) var restoring = false
  mutating func begin() { started = true; restoring = false }
  mutating func restore() { if started { restoring = true } }
  mutating func end(samePlayer: Bool, background: Bool, continuePlaying: Bool) -> Bool {
    defer { self = Self() }
    return started && samePlayer && !restoring && background && !continuePlaying
  }
}
