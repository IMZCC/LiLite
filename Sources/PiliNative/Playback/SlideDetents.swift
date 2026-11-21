import UIKit

/// What a slide on the player feels like: a light detent each time the value passes a tenth of
/// its range (and, for the position, where the slide began), and a firmer stop on reaching either
/// end, as the system's own sliders do. The generators follow the system's haptics switch.
@MainActor final class SlideDetents {
  private let steps: Double
  private var tick: UISelectionFeedbackGenerator?
  private var stop: UIImpactFeedbackGenerator?
  private var step = 0
  /// -1 at the low end, 1 at the high end, 0 between.
  private var end = 0
  /// Which side of the slide's origin the value is on (0 on it).
  private var side = 0
  init(steps: Int = 10) { self.steps = Double(max(1, steps)) }

  /// `fraction` is the value over its range; `origin` the fraction the slide started from.
  func move(_ fraction: Double, origin: Double? = nil) {
    guard fraction.isFinite else { return }
    let f = min(1, max(0, fraction))
    let e = f <= 0.0005 ? -1 : f >= 0.9995 ? 1 : 0
    // At the top end the value counts as just inside it, so leaving the end is not a detent too.
    let s = e == 1 ? Int(steps) - 1 : Int((f * steps).rounded(.down))
    let o = origin.map { o in f > o + 0.0005 ? 1 : f < o - 0.0005 ? -1 : 0 } ?? 0
    guard let tick, let stop else {
      start()
      step = s; end = e; side = o
      return
    }
    if e != 0, e != end {
      stop.impactOccurred(intensity: 0.8)
      stop.prepare()
    } else if e == 0, s != step || (side != 0 && o != side) {
      tick.selectionChanged()
      tick.prepare()
    }
    step = s; end = e; side = o
  }
  func finish() {
    tick = nil
    stop = nil
  }
  private func start() {
    let tick = UISelectionFeedbackGenerator()
    tick.prepare()
    self.tick = tick
    let stop = UIImpactFeedbackGenerator(style: .rigid)
    stop.prepare()
    self.stop = stop
  }
}
