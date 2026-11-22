import AVFoundation
import SwiftUI
import UIKit

/// Pointer scrolling (trackpad, mouse wheel) over the picture changes the volume.
///
/// Nothing is laid over the player for it. It used to be a full-size view on top of the controls
/// that claimed only scroll events in `point(inside:)`; iOS 17 and 18 hit-test a representable
/// by its frame instead, so that view took every touch on the player — taps, drags and the
/// control buttons — and the player could not be operated at all. Now this view only marks the
/// player's area (it is never hit-tested), and a scroll-only recognizer on its window acts on
/// scrolls that land inside it.
struct PointerVolume: UIViewRepresentable {
  let player: any PlaybackEngine
  var changed: (Int) -> Void
  final class Marker: UIView, UIGestureRecognizerDelegate {
    weak var player: (any PlaybackEngine)?
    var changed: ((Int) -> Void)?
    /// The level this scroll is heading for.
    private var target: Double?
    private lazy var pan: UIPanGestureRecognizer = {
      let pan = UIPanGestureRecognizer(target: self, action: #selector(adjust(_:)))
      pan.allowedScrollTypesMask = .all
      // Touches never reach it: fingers, pencil and pointer clicks stay with the player.
      pan.allowedTouchTypes = []
      pan.cancelsTouchesInView = false
      pan.delaysTouchesBegan = false
      pan.delaysTouchesEnded = false
      pan.delegate = self
      return pan
    }()
    override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = .clear
      isUserInteractionEnabled = false
      isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { nil }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      if pan.view !== window {
        pan.view?.removeGestureRecognizer(pan)
        window?.addGestureRecognizer(pan)
      }
    }
    /// Only a scroll over this player while it is on screen (a covered inline player is faded
    /// out under the fullscreen one).
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
      guard recognizer === pan, window != nil, bounds.contains(pan.location(in: self)) else { return false }
      var current: UIView? = self
      while let v = current {
        if v.isHidden || v.alpha < 0.01 { return false }
        current = v.superview
      }
      let d = pan.translation(in: self)
      return abs(d.y) >= abs(d.x)
    }
    /// It sits on the window, so it must never hold up anything else there.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
      true
    }
    @objc func adjust(_ pan: UIPanGestureRecognizer) {
      guard let player, pan.state == .began || pan.state == .changed || pan.state == .ended else { return }
      let dy = pan.translation(in: self).y
      pan.setTranslation(.zero, in: self)
      defer { if pan.state == .ended { target = nil } }
      guard dy.isFinite, dy != 0 else { return }
      // Kept apart from the level in effect: the device's volume moves in sixteenths, which a
      // wheel's small steps would each round back to where they started.
      let next = min(1, max(0, (target ?? PlayerVolume.current(player)) + Double(dy / 4000)))
      target = next
      let set = PlayerVolume.set(next, on: player)
      changed?(Int((set * 100).rounded()))
    }
    func detach() { pan.view?.removeGestureRecognizer(pan) }
  }
  func makeUIView(context: Context) -> Marker { Marker() }
  func updateUIView(_ v: Marker, context: Context) {
    v.player = player; v.changed = changed
  }
  static func dismantleUIView(_ v: Marker, coordinator: ()) { v.detach() }
}
