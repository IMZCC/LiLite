import AVFoundation
import SwiftUI
import UIKit

/// A scroll-only hit surface leaves touches, pencil and pointer clicks to the controls below it.
struct PointerVolume: UIViewRepresentable {
  let player: any PlaybackEngine
  var changed: (Int) -> Void
  final class Surface: UIView, UIGestureRecognizerDelegate {
    weak var player: (any PlaybackEngine)?
    var changed: ((Int) -> Void)?
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
      event?.type == .scroll && bounds.contains(point)
    }
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
      guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
      let d = pan.translation(in: self)
      return abs(d.y) >= abs(d.x)
    }
    @objc func adjust(_ pan: UIPanGestureRecognizer) {
      guard let player, pan.state == .began || pan.state == .changed || pan.state == .ended else { return }
      let dy = pan.translation(in: self).y
      pan.setTranslation(.zero, in: self)
      guard dy.isFinite, dy != 0 else { return }
      let volume = min(1, max(0, player.presentationVolume + Float(dy / 4000)))
      player.presentationVolume = volume
      changed?(Int((volume * 100).rounded()))
    }
  }
  func makeUIView(context: Context) -> Surface {
    let v = Surface()
    v.backgroundColor = .clear; v.isAccessibilityElement = false
    let pan = UIPanGestureRecognizer(target: v, action: #selector(Surface.adjust(_:)))
    pan.allowedScrollTypesMask = .all
    pan.allowedTouchTypes = []
    pan.delegate = v; pan.cancelsTouchesInView = false
    v.addGestureRecognizer(pan)
    return v
  }
  func updateUIView(_ v: Surface, context: Context) {
    v.player = player; v.changed = changed
  }
}
