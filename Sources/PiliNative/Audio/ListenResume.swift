import Foundation

struct ListenInterruptionGate: Equatable {
  private(set) var interrupted = false
  private var wasPlaying = false
  mutating func begin(active: Bool) {
    if !interrupted {
      interrupted = true
      wasPlaying = active
    }
  }
  mutating func finish(shouldResume: Bool) -> Bool {
    let resume = interrupted && wasPlaying && shouldResume
    self = Self()
    return resume
  }
  mutating func invalidate() { self = Self() }
}
struct ListenMark: Codable {
  let track: ListenTrack, anchor: String?, seconds: Double, sourceQueue: Bool
}
