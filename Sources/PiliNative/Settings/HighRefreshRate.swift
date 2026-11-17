import QuartzCore
import UIKit

/// Asks the display for its top refresh rate (120 Hz on ProMotion iPhones) while the app is in
/// the foreground. Uses the system API for this: a `CADisplayLink` whose
/// `preferredFrameRateRange` prefers the maximum rate. The Info.plist already opts in with
/// `CADisableMinimumFrameDurationOnPhone`, without which iPhone apps are capped at 60 Hz.
/// The system still lowers the rate in Low Power Mode or when the device is hot.
@MainActor final class HighRefreshRate {
  static let shared = HighRefreshRate()
  static let key = "display.force120"
  private var link: CADisplayLink?
  private init() {}

  /// Highest rate the current screen supports, e.g. 120 on ProMotion and 60 elsewhere.
  static var maximum: Int {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
      ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    return scene?.screen.maximumFramesPerSecond ?? 60
  }

  /// Start or stop the request; call with `enabled && sceneIsActive`.
  func set(_ on: Bool) {
    let hz = Float(Self.maximum)
    guard on, hz > 60 else {
      link?.invalidate()
      link = nil
      return
    }
    if link == nil {
      let l = CADisplayLink(target: Tick.shared, selector: #selector(Tick.frame(_:)))
      l.add(to: .main, forMode: .common)
      link = l
    }
    link?.preferredFrameRateRange = CAFrameRateRange(minimum: hz, maximum: hz, preferred: hz)
  }

  /// The link only needs to exist; its callback does nothing.
  private final class Tick: NSObject {
    static let shared = Tick()
    @objc func frame(_ link: CADisplayLink) {}
  }
}
