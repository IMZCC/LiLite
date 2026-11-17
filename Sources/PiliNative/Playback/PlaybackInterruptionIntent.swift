/// Only the media item that was actually playing can consume the system's recommendation once.
struct PlaybackInterruptionIntent<Item: Equatable> {
  private var source: Item?
  private var rate: Float = 0
  private(set) var interrupted = false
  mutating func play(_ item: Item, rate: Float) {
    guard rate.isFinite && rate > 0 else { cancel(); return }
    source = item
    self.rate = rate
    interrupted = false
  }
  mutating func interrupt(_ item: Item) {
    guard item == source else { return }
    interrupted = true
  }
  mutating func finish(_ item: Item, allowed: Bool) -> Float? {
    let result = interrupted && item == source && allowed ? rate : nil
    cancel()
    return result
  }
  mutating func cancel() { self = Self() }
}
