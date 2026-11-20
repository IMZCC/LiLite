import SwiftUI
import UIKit

/// 一镜到底: a page opened from a card grows out of that card (its top, where the player or the
/// cover sits, starting in the card's frame) and shrinks back into it on the way back, instead of
/// sliding in from the side.
///
/// Our own push / pop animator rather than the system zoom transition: SwiftUI has no way to limit
/// that one's drag-to-dismiss (UIKit's `interactiveDismissShouldBegin` has no SwiftUI counterpart),
/// and on iOS 26 and 27 its swipe-back is reported to glitch. Cards add no gesture either: a
/// passive window recognizer remembers where the last touch went down, and at push time the card
/// registered under it is the origin.
@MainActor enum CardZoom {
  /// Card frames on screen, in window points (SwiftUI's global space at interface scale 1).
  fileprivate static let cards = NSHashTable<FrameBox>.weakObjects()
  private static var touch: (point: CGPoint, time: TimeInterval)?
  private static let origins = NSMapTable<UIViewController, OriginBox>.weakToStrongObjects()
  private static let watched = NSHashTable<UIWindow>.weakObjects()

  static func watch(_ window: UIWindow?) {
    guard let window, !watched.contains(window) else { return }
    watched.add(window)
    window.addGestureRecognizer(TouchWatch())
  }
  fileprivate static func touched(_ point: CGPoint?) {
    touch = point.map { ($0, ProcessInfo.processInfo.systemUptime) }
  }
  /// The card just tapped: the smallest registered frame under the last touch, if that touch is
  /// recent enough to be the one that opened the page.
  private static func tappedCard() -> CGRect? {
    guard let touch, ProcessInfo.processInfo.systemUptime - touch.time < 1.5 else { return nil }
    var best: CGRect?
    for box in cards.allObjects where box.frame.width >= 44 && box.frame.height >= 30 && box.frame.contains(touch.point) {
      if best.map({ box.frame.width * box.frame.height < $0.width * $0.height }) ?? true { best = box.frame }
    }
    return best
  }
  static func pushAnimator(to page: UIViewController) -> UIViewControllerAnimatedTransitioning? {
    guard !UIAccessibility.isReduceMotionEnabled, let card = tappedCard() else { return nil }
    touch = nil
    origins.setObject(OriginBox(card), forKey: page)
    return CardZoomAnimator(origin: card, opening: true)
  }
  /// For a page that was opened from a card: the animator that shrinks it back into that card.
  static func popAnimator(from page: UIViewController) -> UIViewControllerAnimatedTransitioning? {
    guard !UIAccessibility.isReduceMotionEnabled, let box = origins.object(forKey: page) else { return nil }
    return CardZoomAnimator(origin: box.frame, opening: false)
  }
}

final class FrameBox: NSObject {
  var frame = CGRect.zero
}
private final class OriginBox: NSObject {
  let frame: CGRect
  init(_ frame: CGRect) { self.frame = frame }
}

/// Notes where each touch goes down and steps aside at once: it never recognizes, never delays or
/// cancels a touch, and never blocks another recognizer.
private final class TouchWatch: UIGestureRecognizer {
  init() {
    super.init(target: nil, action: nil)
    cancelsTouchesInView = false
    delaysTouchesBegan = false
    delaysTouchesEnded = false
  }
  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    if let t = touches.first, let window = view as? UIWindow {
      CardZoom.touched(Self.floating(t.view, in: window) ? nil : t.location(in: window))
    }
    state = .failed
  }
  /// A sheet, alert or menu over the cards is not a card: a pick there opens its page plainly.
  private static func floating(_ touched: UIView?, in window: UIWindow) -> Bool {
    var presented = window.rootViewController?.presentedViewController
    while let page = presented {
      if let host = page.viewIfLoaded, touched?.isDescendant(of: host) == true { return true }
      presented = page.presentedViewController
    }
    var view = touched
    while let current = view {
      // The class's own name only: a SwiftUI hosting view's generic arguments spell out the
      // whole view tree under it, so every touch would look like one on a menu or an alert.
      let name = String(describing: type(of: current)).prefix { $0 != "<" }
      if name.contains("Menu") || name.contains("Alert") { return true }
      view = current.superview
    }
    return false
  }
  override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
  override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
}

private struct CardZoomKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
  /// Whether links built with `LazyLink` here open their page out of the card (on by default).
  var cardZoom: Bool {
    get { self[CardZoomKey.self] }
    set { self[CardZoomKey.self] = newValue }
  }
}

/// Registers the view's frame as a card a page can grow out of, while it is on screen.
struct CardZoomSource: ViewModifier {
  @State private var box = FrameBox()
  @Environment(\.cardZoom) private var enabled
  /// Scaled, SwiftUI's global frames are no longer window points: such cards open plainly.
  @Environment(\.interfaceScaled) private var scaled
  @ViewBuilder func body(content: Content) -> some View {
    if enabled && !scaled {
      content
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { box.frame = $0 }
        .onAppear { CardZoom.cards.add(box) }
        .onDisappear { CardZoom.cards.remove(box) }
    } else {
      content
    }
  }
}

final class CardZoomAnimator: NSObject, UIViewControllerAnimatedTransitioning {
  let origin: CGRect, opening: Bool
  init(origin: CGRect, opening: Bool) {
    self.origin = origin
    self.opening = opening
  }
  func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
    opening ? 0.46 : 0.38
  }
  func animateTransition(using ctx: UIViewControllerContextTransitioning) {
    guard let fromView = ctx.view(forKey: .from), let toView = ctx.view(forKey: .to),
      let toVC = ctx.viewController(forKey: .to)
    else { ctx.completeTransition(false); return }
    let container = ctx.containerView
    let final = ctx.finalFrame(for: toVC)
    toView.frame = final.isEmpty ? container.bounds : final
    let page = opening ? toView : fromView, under = opening ? fromView : toView
    if opening { container.addSubview(toView) } else { container.insertSubview(toView, belowSubview: fromView) }
    let card = container.convert(origin, from: nil)
    let frame = page.frame, bounds = page.bounds
    // Collapsed: the page at the card's width, its top-left on the card's, cut to the card's height.
    let s = max(0.05, min(1, card.width / max(1, frame.width)))
    let collapsed = CGAffineTransform(
      translationX: card.minX - (frame.midX - frame.width * s / 2),
      y: card.minY - (frame.midY - frame.height * s / 2)
    ).scaledBy(x: s, y: s)
    let small = CGRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, card.height / s))
    let mask = UIView(frame: bounds)
    mask.backgroundColor = .black
    mask.layer.cornerCurve = .continuous
    page.mask = mask
    let dim = UIView(frame: container.bounds)
    dim.backgroundColor = .black
    dim.isUserInteractionEnabled = false
    container.insertSubview(dim, aboveSubview: under)
    let radius = 10 / s
    func set(collapsed c: Bool) {
      page.transform = c ? collapsed : .identity
      mask.frame = c ? small : bounds
      mask.layer.cornerRadius = c ? radius : 0
      dim.alpha = c ? 0 : 0.16
    }
    set(collapsed: opening)
    let finish: (Bool) -> Void = { _ in
      page.transform = .identity
      page.mask = nil
      page.alpha = 1
      dim.removeFromSuperview()
      if ctx.transitionWasCancelled { toView.removeFromSuperview() }
      ctx.completeTransition(!ctx.transitionWasCancelled)
    }
    let duration = transitionDuration(using: ctx)
    if opening && !ctx.isInteractive {
      UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
        options: [.allowUserInteraction], animations: { set(collapsed: false) }, completion: finish)
    } else {
      // Back into the card, fading out over the last stretch so the card itself shows through.
      // Linear while a finger drives it, so the page follows the drag.
      let closing = !opening
      UIView.animateKeyframes(withDuration: duration, delay: 0,
        options: ctx.isInteractive ? [.calculationModeLinear] : [.calculationModeCubic],
        animations: {
          UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 1) { set(collapsed: closing) }
          if closing {
            UIView.addKeyframe(withRelativeStartTime: 0.72, relativeDuration: 0.28) { page.alpha = 0 }
          }
        }, completion: finish)
    }
  }
}
