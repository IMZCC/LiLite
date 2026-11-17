import SwiftUI
import UIKit

@MainActor final class PlayerKeyFocus: ObservableObject {
  weak var marker: UIView?
  /// SwiftUI can keep a covered inline video mounted in another presentation. Only the visible
  /// hosting tree in the key window may act on its keys or complete a timed hold.
  func available() -> Bool {
    guard let marker, let window = marker.window, window.isKeyWindow,
      window.windowScene?.activationState == .foregroundActive, let root = window.rootViewController
    else { return false }
    var current: UIView? = marker
    while let v = current {
      if v.isHidden || v.alpha < 0.01 { return false }
      current = v.superview
    }
    var top = root
    while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
    guard top === root || (top.viewIfLoaded.map { marker.isDescendant(of: $0) } ?? false) else {
      return false
    }
    func editing(_ view: UIView) -> Bool {
      guard !view.isHidden else { return false }
      if view.isFirstResponder, view is any UITextInput { return true }
      return view.subviews.contains(where: editing)
    }
    return !editing(window)
  }
}
struct PlayerKeyFocusMarker: UIViewRepresentable {
  let owner: PlayerKeyFocus
  func makeUIView(context: Context) -> UIView {
    let v = UIView()
    v.isUserInteractionEnabled = false
    v.isAccessibilityElement = false
    owner.marker = v
    return v
  }
  func updateUIView(_ view: UIView, context: Context) { owner.marker = view }
}
