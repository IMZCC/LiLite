import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import UIKit

/// The device's volume, set the way the official client sets it (BBPlayerSystemVolumeWidget):
/// through the slider inside an `MPVolumeView` kept just outside the window's bounds while a
/// player is on screen. Being in the window, that view also keeps the system's volume HUD away,
/// so the player shows its own level, for the volume buttons as well. Levels go in the buttons'
/// sixteenths, as the official client rounds them.
@MainActor final class SystemVolume {
  static let shared = SystemVolume()
  private let view = MPVolumeView(frame: CGRect(x: -233, y: -233, width: 1, height: 1))
  private var anchors = 0
  private var observation: NSKeyValueObservation?
  /// Until when a change of `outputVolume` is our own `set`, not the buttons.
  private var settingUntil: TimeInterval = 0
  /// A level set by the volume buttons (or Control Centre) while a player is on screen.
  let external = PassthroughSubject<Double, Never>()

  private init() {
    view.isUserInteractionEnabled = false
    view.accessibilityElementsHidden = true
  }

  /// Whether the device's volume can be set from here. The simulator has none to set; its
  /// player then changes its own gain, as before.
  var available: Bool {
    #if targetEnvironment(simulator)
      return false
    #else
      return view.window != nil && slider != nil
    #endif
  }
  /// The device's volume, 0…1.
  var level: Double { Double(AVAudioSession.sharedInstance().outputVolume) }

  /// Sets the device's volume to the nearest sixteenth and returns the level now in effect.
  @discardableResult func set(_ value: Double) -> Double {
    let stepped = Self.stepped(value)
    guard let slider else { return stepped }
    if Float(stepped) != slider.value {
      settingUntil = ProcessInfo.processInfo.systemUptime + 0.6
      slider.setValue(Float(stepped), animated: false)
    }
    return stepped
  }
  static func stepped(_ value: Double) -> Double { (min(1, max(0, value)) * 16).rounded() / 16 }

  private var slider: UISlider? { Self.slider(in: view) }
  private static func slider(in view: UIView) -> UISlider? {
    for sub in view.subviews {
      if let slider = sub as? UISlider { return slider }
      if let found = slider(in: sub) { return found }
    }
    return nil
  }

  /// A player came on screen in `window`.
  fileprivate func attach(_ window: UIWindow) {
    anchors += 1
    if view.window !== window {
      view.frame = CGRect(x: -233, y: -233, width: 1, height: 1)
      window.addSubview(view)
    }
    guard observation == nil else { return }
    observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
      guard let value = change.newValue else { return }
      Task { @MainActor in
        guard let self, ProcessInfo.processInfo.systemUptime > self.settingUntil else { return }
        self.external.send(Double(value))
      }
    }
  }
  /// The last player on screen went: the system shows its own volume HUD again.
  fileprivate func detach() {
    anchors = max(0, anchors - 1)
    guard anchors == 0 else { return }
    observation = nil
    view.removeFromSuperview()
  }
}

/// The volume a player's controls change: the device's where it can be set, as the official
/// client does, the player's own gain otherwise.
@MainActor enum PlayerVolume {
  static func current(_ player: any PlaybackEngine) -> Double {
    SystemVolume.shared.available ? SystemVolume.shared.level : Double(player.presentationVolume)
  }
  /// Sets it and returns the level now in effect.
  @discardableResult static func set(_ value: Double, on player: any PlaybackEngine) -> Double {
    if SystemVolume.shared.available { return SystemVolume.shared.set(value) }
    let level = min(1, max(0, value))
    player.presentationVolume = Float(level)
    return level
  }
  /// One press of a volume key: a button's step on the device, a tenth on the player.
  static var step: Double { SystemVolume.shared.available ? 1.0 / 16 : 0.1 }
}

/// Marks a player on screen, so the device's volume can be set and its HUD kept to the player.
struct SystemVolumeAnchor: UIViewRepresentable {
  final class Marker: UIView {
    private var attached = false
    override func didMoveToWindow() {
      super.didMoveToWindow()
      if let window, !attached {
        attached = true
        SystemVolume.shared.attach(window)
      } else if window == nil, attached {
        attached = false
        SystemVolume.shared.detach()
      }
    }
  }
  func makeUIView(context: Context) -> Marker {
    let marker = Marker()
    marker.isUserInteractionEnabled = false
    return marker
  }
  func updateUIView(_ view: Marker, context: Context) {}
}
