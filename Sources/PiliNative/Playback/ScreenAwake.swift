import UIKit

/// Keeps the display from dimming and locking while a video plays on screen. mpv draws into its
/// own layer, so the system never learns a video is showing (AVPlayer's layer only covers
/// itself) and the auto-lock timer ran out mid-video. Each on-screen player holds the screen
/// while it plays; the timer runs again once none does.
@MainActor final class ScreenAwake: NSObject {
  static let shared = ScreenAwake()
  private var holders = Set<UUID>()
  override private init() {
    super.init()
    // Set again on return to the foreground: the flag is not guaranteed to survive a trip
    // through the background.
    NotificationCenter.default.addObserver(
      self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification,
      object: nil)
  }
  func hold(_ token: UUID, _ awake: Bool) {
    let changed = awake ? holders.insert(token).inserted : holders.remove(token) != nil
    if changed { apply() }
  }
  @objc private func becameActive() { apply() }
  private func apply() {
    UIApplication.shared.isIdleTimerDisabled = !holders.isEmpty
  }
}
