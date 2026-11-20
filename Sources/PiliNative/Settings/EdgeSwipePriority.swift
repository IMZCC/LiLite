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
    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      visible = true
      attach()
    }
    override func viewWillDisappear(_ animated: Bool) {
      super.viewWillDisappear(animated)
      visible = false
      detach()
    }
    private func attach() {
      guard visible, driver == nil, let nav = navigationController, nav.viewControllers.count > 1,
        let owner = nav.topViewController, let host = owner.viewIfLoaded,
        view.isDescendant(of: host) else { return }
      didAttach(nav)
      if self.owner !== owner || pan == nil {
        detach()
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
      if let contentWasEnabled { nav?.piliContentPopGesture?.isEnabled = contentWasEnabled }
      contentWasEnabled = nil
      // Restore the shared recognizer before the next page appears. Keep our own pan
      // alive until UIKit finishes or cancels the interaction that it is driving.
      guard driver == nil else { return }
      if let pan { pan.view?.removeGestureRecognizer(pan) }
      pan = nil
      nav = nil
      owner = nil
    }
    private func sign(_ view: UIView) -> CGFloat {
      view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
    }
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
      guard visible, let host = gesture.view, nav?.topViewController === owner else { return false }
      let x = touch.location(in: host).x
      return fullWidth || (sign(host) > 0 ? x - host.bounds.minX : host.bounds.maxX - x) <= 28
    }
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
      guard let pan = gesture as? UIPanGestureRecognizer, let host = pan.view,
        let nav, let owner, nav.topViewController === owner, nav.viewControllers.count > 1,
        !NavigationPopBlock.blocks(owner),
        nav.transitionCoordinator == nil, driver == nil, nav.presentedViewController == nil,
        owner.presentedViewController == nil else { return false }
      let velocity = pan.velocity(in: host)
      return velocity.x * sign(host) > abs(velocity.y)
    }
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
      if other === nav?.interactivePopGestureRecognizer || other === nav?.piliContentPopGesture { return true }
      guard let host = owner?.viewIfLoaded, let otherView = other.view else { return false }
      return otherView.isDescendant(of: host)
    }
    @objc private func drag(_ pan: UIPanGestureRecognizer) {
      guard let nav, let container = nav.viewIfLoaded else { return }
      let direction = sign(container)
      let progress = min(1, max(0, direction * pan.translation(in: container).x / max(1, container.bounds.width)))
      switch pan.state {
      case .began:
        let transition = LeadingPopTransition()
        driver = transition
        transition.begin(in: nav, rtl: direction < 0) { [self] in
          driver = nil
          if let owner, nav.topViewController === owner { attach() } else { detach() }
        }
      case .changed:
        driver?.interaction.update(progress)
      case .ended:
        let speed = pan.velocity(in: container).x * direction
        if speed > 500 || (progress >= 0.4 && speed > -300) { driver?.interaction.finish() }
        else { driver?.interaction.cancel() }
      case .failed, .cancelled:
        driver?.interaction.cancel()
      default: break
      }
    }
  }
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
  let interaction = UIPercentDrivenInteractiveTransition()
  private weak var original: UINavigationControllerDelegate?
  private var animator: UIViewControllerAnimatedTransitioning?

  func begin(in nav: UINavigationController, rtl: Bool, completion: @escaping () -> Void) {
    original = nav.delegate
    // A page opened from a card shrinks back into it under the finger (一镜到底); others slide.
    animator = nav.topViewController.flatMap { CardZoom.popAnimator(from: $0) }
      ?? MotionAnimator(mode: rtl ? .fromLeft : .fromRight, opening: false)
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
    if animation === animator { return interaction }
    return original?.navigationController?(nav, interactionControllerFor: animation)
  }
}
