import Foundation

enum InterfaceInteraction {
  static let preinitialize = "play.preinitialize", pauseWhenBackground = "play.pauseWhenBackground"
  static let horizontal = "gesture.horizontalThreshold", displacement = "list.refreshDisplacement",
    scale = "layout.interfaceScale"
  static func bounded(_ v: Double, within range: ClosedRange<Double>, fallback: Double) -> Double {
    v.isFinite ? min(range.upperBound, max(range.lowerBound, v)) : fallback
  }
  static func horizontalDrag(x: Double, y: Double, threshold: Double) -> Bool {
    abs(x) > bounded(threshold, within: 0...200, fallback: 24) && abs(x) > 3 * abs(y)
  }
  static func distance(_ value: Double) -> Double { bounded(value, within: 10...100, fallback: 20) }
  static func refreshThreshold(_ displacement: Double) -> Double { distance(displacement) + 49 }
  static func interfaceScale(_ value: Double) -> Double {
    bounded(value, within: 0.5...2, fallback: 1)
  }
}
struct PlaybackEntryID: Equatable {
  let source: String, cid: Int64, owner: String?
}
enum PlaybackEntryMode { case cover, preparePaused, play }
enum PlaybackEntryPolicy {
  static func mode(preinitialize: Bool, autoplay: Bool, manual: Bool, continuation: Bool)
    -> PlaybackEntryMode
  {
    if autoplay || manual || continuation { return .play }
    return preinitialize ? .preparePaused : .cover
  }
}

struct SceneResumeMemory<Item: Equatable> {
  private(set) var item: Item?, rate: Float = 0, background = false
  mutating func capture(item: Item?, rate: Float, wanted: Bool) {
    self = Self()
    guard wanted, let item, rate.isFinite, rate > 0 else { return }
    self.item = item
    self.rate = rate
  }
  mutating func enter(current: Item?, eligible: Bool) -> Bool {
    guard let item, current == item, eligible else {
      self = Self()
      return false
    }
    background = true
    return true
  }
  func restore(current: Item?, eligible: Bool, paused: Bool) -> Float? {
    guard background, eligible, paused, let item, current == item else { return nil }
    return rate
  }
}
