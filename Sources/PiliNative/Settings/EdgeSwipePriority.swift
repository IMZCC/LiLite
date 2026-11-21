import SwiftUI
import UIKit

/// A pushed page can reserve its leading edge for Back while keeping its horizontal pager
/// or player controls interactive elsewhere. At the root, the pager owns the entire width.
struct LeadingEdgeNavigation: UIViewControllerRepresentable {
  var fullWidth = false
  var didAttach: (UINavigationController) -> Void = { _ in }
  func makeUIViewController(context: Context) -> Probe { Probe() }
  func updateUIViewController(_ probe: Probe, context: Context) {
    probe.fullWidth = fullWidth
    probe.didAttach = didAttach
  }
  static func dismantleUIViewController(_ probe: Probe, coordinator: ()) { probe.detach() }

  final class Probe: UIViewController, UIGestureRecognizerDelegate {
    var fullWidth = false
    var didAttach: (UINavigationController) -> Void = { _ in }
    private weak var nav: UINavigationController?
    private weak var owner: UIViewController?
    private var pan: UIPanGestureRecognizer?
    private var contentWasEnabled: Bool?
    private var driver: LeadingPopTransition?
    private var visible = false

    override func loadView() {
      view = UIView()
      view.isUserInteractionEnabled = false
    }
    private var edgeWasEnabled: Bool?
    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      visible = true
      uncover()
      attach()
    }
    override func viewWillDisappear(_ animated: Bool) {
      super.viewWillDisappear(animated)
      visible = false
      // Covered by something presented over the page (a picture viewer), not left: Back stays
      // off, the system's edge swipe too, so a swipe inside the cover never pops the page beneath.
      if let nav, let owner, nav.topViewController === owner,
        nav.view.window?.rootViewController?.presentedViewController != nil {
        if edgeWasEnabled == nil, let edge = nav.interactivePopGestureRecognizer {
          edgeWasEnabled = edge.isEnabled
          edge.isEnabled = false
        }
        return
      }
      detach()
    }
    private func uncover() {
      if let edgeWasEnabled { nav?.interactivePopGestureRecognizer?.isEnabled = edgeWasEnabled }
      edgeWasEnabled = nil
    }
    private func attach() {
      guard visible, driver == nil, let nav = navigationController, nav.viewControllers.count > 1,
        let owner = nav.topViewController, let host = owner.viewIfLoaded,
        view.isDescendant(of: host) else { return }
      // A page the system's zoom opened goes back by the zoom's own gestures.
      guard !CardZoom.systemZoom(owner) else { detach(); return }
      didAttach(nav)
      // One Back swipe per page: a second probe on the same page (a pager's inside a page that
      // has its own) would wait on the first while the first waits on it, and neither would run.
      if let holder = Self.claims.object(forKey: owner), holder !== self, holder.pan != nil { return }
      Self.claims.setObject(self, forKey: owner)
      if self.owner !== owner || pan == nil {
        detach()
        Self.claims.setObject(self, forKey: owner)
        self.nav = nav
        self.owner = owner
        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        host.addGestureRecognizer(pan)
        self.pan = pan
      }
      if contentWasEnabled == nil, let content = nav.piliContentPopGesture {
        contentWasEnabled = content.isEnabled
        content.isEnabled = false
      }
    }
    func detach() {
      uncover()
      if let contentWasEnabled { nav?.piliContentPopGesture?.isEnabled = contentWasEnabled }
      contentWasEnabled = nil
      // Restore the shared recognizer before the next page appears. Keep our own pan
      // alive until UIKit finishes or cancels the interaction that it is driving.
      guard driver == nil else { return }
      if let pan { pan.view?.removeGestureRecognizer(pan) }
      pan = nil
      if let owner, Self.claims.object(forKey: owner) === self { Self.claims.removeObject(forKey: owner) }
      nav = nil
      owner = nil
    }
    @MainActor private static let claims = NSMapTable<UIViewController, Probe>.weakToWeakObjects()
    private func sign(_ view: UIView) -> CGFloat {
      view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
    }
    private func atEdge(_ point: CGPoint, in host: UIView) -> Bool {
      (sign(host) > 0 ? point.x - host.bounds.minX : host.bounds.maxX - point.x) <= 28
    }
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
      guard visible, let host = gesture.view, nav?.topViewController === owner else { return false }
      if atEdge(touch.location(in: host), in: host) { return true }
      // Away from the edge, a player keeps its sideways drags (seeking).
      return fullWidth && !BackSwipeExclusion.covers(touch.location(in: nil), in: host)
    }
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
      guard let pan = gesture as? UIPanGestureRecognizer, let host = pan.view,
        let nav, let owner, nav.topViewController === owner, nav.viewControllers.count > 1,
        !NavigationPopBlock.blocks(owner), !CardZoom.busy, !CardZoom.systemZoom(owner),
        nav.transitionCoordinator == nil, driver == nil, nav.presentedViewController == nil,
        owner.presentedViewController == nil else { return false }
      let velocity = pan.velocity(in: host)
      guard velocity.x * sign(host) > abs(velocity.y) else { return false }
      let moved = pan.translation(in: host), now = pan.location(in: host)
      let start = CGPoint(x: now.x - moved.x, y: now.y - moved.y)
      // As with the system's content swipe: a sideways list or pager that can still scroll back
      // takes the swipe; at its start, the swipe goes Back.
      return atEdge(start, in: host) || !scrollsBack(at: start, in: host)
    }
    private func scrollsBack(at point: CGPoint, in host: UIView) -> Bool {
      let rtl = sign(host) < 0
      var view = host.hitTest(point, with: nil)
      while let current = view, current !== host {
        if let scroll = current as? UIScrollView, scroll.isScrollEnabled, scroll.panGestureRecognizer.isEnabled {
          let inset = scroll.adjustedContentInset
          let low = -inset.left, high = scroll.contentSize.width + inset.right - scroll.bounds.width
          if high > low + 1 {
            let x = scroll.contentOffset.x
            if rtl ? x < high - 1 : x > low + 1 { return true }
          }
        }
        view = current.superview
      }
      return false
    }
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
      if other === nav?.interactivePopGestureRecognizer || other === nav?.piliContentPopGesture { return true }
      guard let host = owner?.viewIfLoaded, let otherView = other.view else { return false }
      return otherView.isDescendant(of: host)
    }
    @objc private func drag(_ pan: UIPanGestureRecognizer) {
      guard let nav, let container = nav.viewIfLoaded else { return }
      let direction = sign(container)
      let translation = pan.translation(in: container)
      let progress = min(1, max(0, direction * translation.x / max(1, container.bounds.width)))
      switch pan.state {
      case .began:
        let transition = LeadingPopTransition()
        driver = transition
        let finger = pan.location(in: container)
        transition.begin(
          in: nav, rtl: direction < 0, touch: CGPoint(x: finger.x - translation.x, y: finger.y - translation.y)
        ) { [self] in
          driver = nil
          if let owner, nav.topViewController === owner { attach() } else { detach() }
        }
      case .changed:
        driver?.update(progress, translation: translation)
      case .ended:
        let velocity = pan.velocity(in: container), speed = velocity.x * direction
        // A page held under the finger (一镜到底) lets go sooner than one that slides, and its
        // progress is the fold's, on a phone's reach whatever the window's width.
        let folded = min(1, max(0, direction * translation.x / CardZoom.dragSpan(container.bounds.width)))
        let through = driver?.zooming == true
          ? speed > 300 || (folded >= 0.25 && speed > -200)
          : speed > 500 || (progress >= 0.4 && speed > -300)
        driver?.end(finish: through, velocity: velocity)
      case .failed, .cancelled:
        driver?.end(finish: false, velocity: .zero)
      default: break
      }
    }
  }
}

/// Where sideways drags belong to the content (a player's seeking), a page's full-width Back
/// swipe stands aside. A swipe from the screen's edge still goes Back, as the system's does.
struct BackSwipeExclusion: UIViewRepresentable {
  func makeUIView(context: Context) -> Marker { Marker() }
  func updateUIView(_ view: Marker, context: Context) {}
  @MainActor private static let markers = NSHashTable<Marker>.weakObjects()
  /// `point` is in window coordinates.
  @MainActor static func covers(_ point: CGPoint, in host: UIView) -> Bool {
    markers.allObjects.contains { marker in
      marker.window === host.window && !marker.isHidden && marker.isDescendant(of: host)
        && marker.convert(marker.bounds, to: nil).contains(point)
    }
  }
  final class Marker: UIView {
    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { nil }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window != nil { BackSwipeExclusion.markers.add(self) } else { BackSwipeExclusion.markers.remove(self) }
    }
  }
}
extension View {
  /// See `BackSwipeExclusion`.
  func backSwipeExclusion() -> some View { background(BackSwipeExclusion().accessibilityHidden(true)) }
}

/// While something inside the page that closes with a sideways swipe is open (a comment thread
/// panel in the video page), the page's back swipes stand aside: the swipe closes that, not the
/// page, as in the official client.
struct NavigationPopBlock: UIViewControllerRepresentable {
  let active: Bool
  @MainActor private static let owners = NSHashTable<UIViewController>.weakObjects()
  @MainActor static func blocks(_ owner: UIViewController) -> Bool { owners.contains(owner) }
  func makeUIViewController(context: Context) -> Probe { Probe() }
  func updateUIViewController(_ probe: Probe, context: Context) {
    probe.active = active
    probe.apply()
  }
  static func dismantleUIViewController(_ probe: Probe, coordinator: ()) { probe.release() }

  final class Probe: UIViewController {
    var active = false
    private var visible = false
    private weak var nav: UINavigationController?
    private weak var owner: UIViewController?
    private var native: Bool?, content: Bool?
    override func loadView() {
      view = UIView()
      view.isUserInteractionEnabled = false
    }
    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      visible = true
      apply()
    }
    override func viewWillDisappear(_ animated: Bool) {
      super.viewWillDisappear(animated)
      visible = false
      release()
    }
    func apply() {
      guard active else { release(); return }
      guard visible, owner == nil, let nav = navigationController, let owner = nav.topViewController,
        let host = owner.viewIfLoaded, view.isDescendant(of: host) else { return }
      self.nav = nav
      self.owner = owner
      NavigationPopBlock.owners.add(owner)
      if let g = nav.interactivePopGestureRecognizer { native = g.isEnabled; g.isEnabled = false }
      if let g = nav.piliContentPopGesture { content = g.isEnabled; g.isEnabled = false }
    }
    func release() {
      if let owner { NavigationPopBlock.owners.remove(owner) }
      if let native { nav?.interactivePopGestureRecognizer?.isEnabled = native }
      if let content { nav?.piliContentPopGesture?.isEnabled = content }
      native = nil
      content = nil
      owner = nil
      nav = nil
    }
  }
}

/// Supply the animator and its interaction only for this pop. SwiftUI continues receiving the
/// navigation delegate callbacks that keep its stack in sync when the user finishes or cancels.
@MainActor final class LeadingPopTransition: NSObject, UINavigationControllerDelegate {
  private let interaction = UIPercentDrivenInteractiveTransition()
  private weak var original: UINavigationControllerDelegate?
  private var animator: UIViewControllerAnimatedTransitioning?
  /// Set for a page opened from a card: it goes back into the card under the finger (一镜到底),
  /// driving itself. Other pages slide, scrubbed by `interaction`.
  private var zoom: CardZoomTransition?
  var zooming: Bool { zoom != nil }

  func update(_ progress: CGFloat, translation: CGPoint) {
    if let zoom { zoom.drag(translation) } else { interaction.update(progress) }
  }
  func end(finish: Bool, velocity: CGPoint) {
    if let zoom { zoom.end(finish: finish, velocity: velocity) }
    else if finish { interaction.finish() }
    else { interaction.cancel() }
  }
  /// `touch` is where the finger went down, in the navigation controller's view.
  func begin(in nav: UINavigationController, rtl: Bool, touch: CGPoint, completion: @escaping () -> Void) {
    original = nav.delegate
    zoom = nav.topViewController.flatMap { CardZoom.interactivePop(from: $0, touch: touch, rtl: rtl) }
    animator = zoom ?? MotionAnimator(mode: rtl ? .fromLeft : .fromRight, opening: false)
    interaction.completionCurve = .easeOut
    nav.delegate = self
    let popped = nav.popViewController(animated: true)
    if popped != nil, let back = nav.topViewController { ListRowSelection.clear(in: back, along: nav.transitionCoordinator) }
    let finish = { [self] in
      if nav.delegate === self { nav.delegate = original }
      completion()
    }
    if popped != nil, let transition = nav.transitionCoordinator,
      transition.animate(alongsideTransition: nil, completion: { _ in finish() }) { return }
    finish()
  }
  override func responds(to selector: Selector!) -> Bool {
    super.responds(to: selector) || original?.responds(to: selector) == true
  }
  override func forwardingTarget(for selector: Selector!) -> Any? {
    if original?.responds(to: selector) == true { return original }
    return super.forwardingTarget(for: selector)
  }
  func navigationController(_ nav: UINavigationController, animationControllerFor operation: UINavigationController.Operation,
    from fromVC: UIViewController, to toVC: UIViewController) -> UIViewControllerAnimatedTransitioning? {
    if operation == .pop { return animator }
    return original?.navigationController?(nav, animationControllerFor: operation, from: fromVC, to: toVC)
  }
  func navigationController(_ nav: UINavigationController,
    interactionControllerFor animation: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
    if animation === animator { return zoom.map { $0 as UIViewControllerInteractiveTransitioning } ?? interaction }
    return original?.navigationController?(nav, interactionControllerFor: animation)
  }
}
