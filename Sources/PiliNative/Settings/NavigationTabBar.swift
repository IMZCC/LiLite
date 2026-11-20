import SwiftUI
import UIKit

/// Observe the root controller's navigation transitions without replacing either delegate.
struct NavigationTabBarProbe: UIViewControllerRepresentable {
  let changed: (Bool) -> Void
  func makeUIViewController(context: Context) -> Probe { Probe(changed: changed) }
  func updateUIViewController(_ controller: Probe, context: Context) {
    controller.changed = changed
  }
  static func dismantleUIViewController(_ controller: Probe, coordinator: ()) {
    controller.generation &+= 1
    controller.changed = { _ in }
  }

  final class Probe: UIViewController {
    var changed: (Bool) -> Void
    var generation = 0
    init(changed: @escaping (Bool) -> Void) {
      self.changed = changed
      super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
      view = UIView(); view.isUserInteractionEnabled = false; view.accessibilityElementsHidden = true
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); observe() }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); observe() }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); settle() }

    private func observe() {
      guard let nav = navigationController, let tabs = nav.tabBarController,
        let root = nav.viewControllers.first else { return }
      generation &+= 1
      let ticket = generation
      let bar = tabs.tabBar
      guard let transition = nav.transitionCoordinator else {
        bar.alpha = 1
        publish(nav.topViewController !== root, ticket: ticket)
        return
      }
      // A modal presentation is not a push and must not change the underlying tab bar.
      let destination = transition.viewController(forKey: .to)
      let target = destination.flatMap { candidate in
        nav.viewControllers.contains(where: { $0 === candidate }) ? candidate : nil
      } ?? nav.topViewController
      let hide = target !== root
      let leavingRoot = hide && transition.viewController(forKey: .from) === root
      // The bar belongs to the root page, as in the official client: while a page opens over the
      // root or closes back onto it, the bar is a picture on the root page, so the other page
      // covers and uncovers it like the rest of the root page (sliding in over it, or growing out
      // of a card and shrinking back into it). The real bar's hidden state (SwiftUI's toolbar,
      // which resizes both pages) changes only before or after the transition, under the picture.
      if leavingRoot, keepGhost(of: bar, in: tabs), let picture = pinGhost(on: root, nav: nav, tabs: tabs) {
        bar.alpha = 0
        transition.animate(alongsideTransition: nil) { [weak self, weak nav] _ in
          picture.removeFromSuperview()
          guard let self, let nav, self.generation == ticket else { return }
          let hidden = nav.topViewController !== nav.viewControllers.first
          if !hidden { bar.alpha = 1 }
          self.publish(hidden, ticket: ticket)
        }
        return
      }
      if !hide, let picture = pinGhost(on: root, nav: nav, tabs: tabs) {
        // Lift the picture once the real bar is drawn in its place.
        let lift = { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { picture.removeFromSuperview() } }
        transition.animate(alongsideTransition: nil) { [weak self, weak nav] context in
          guard let self, let nav, self.generation == ticket else { lift(); return }
          let hidden = nav.topViewController !== nav.viewControllers.first
          guard !hidden, !context.isCancelled else {
            // Swipe called off: the picture waits for the next way back.
            picture.removeFromSuperview()
            self.publish(true, ticket: ticket)
            return
          }
          self.ghost = nil
          bar.alpha = 1
          if #available(iOS 18, *) { tabs.setTabBarHidden(false, animated: false) }
          self.changed(false)
          lift()
        }
        return
      }
      if transition.initiallyInteractive {
        // Changing SwiftUI toolbar visibility resizes both hosting controllers and their
        // pagers. Keep that layout stable until the system finishes or cancels the swipe.
        transition.animate(alongsideTransition: hide ? { _ in bar.alpha = 0 } : nil) { [weak self, weak nav] _ in
          guard let self, let nav, self.generation == ticket else { return }
          let hidden = nav.topViewController !== nav.viewControllers.first
          bar.alpha = hidden ? 0 : 1
          self.publish(hidden, ticket: ticket)
        }
        return
      }
      if hide {
        // Push (or pop between two pushed pages): fade the bar out with the transition and only
        // commit the hidden state once it has finished, so nothing pops at the start.
        transition.animate(alongsideTransition: { _ in bar.alpha = 0 }) { [weak self, weak nav] context in
          guard let self, let nav, self.generation == ticket else { return }
          let hidden = nav.topViewController !== nav.viewControllers.first
          if context.isCancelled && !hidden { bar.alpha = 1 }
          self.publish(hidden, ticket: ticket)
        }
      } else {
        // Pop back to the root: make the bar present but transparent, then let its opacity follow
        // the interactive gesture. A cancelled swipe fades it back out and keeps it hidden.
        bar.alpha = 0
        publish(false, ticket: ticket)
        transition.animate(alongsideTransition: { _ in bar.alpha = 1 }) { [weak self, weak nav] context in
          guard let self, let nav, self.generation == ticket else { return }
          let hidden = nav.topViewController !== nav.viewControllers.first
          bar.alpha = hidden ? 0 : 1
          self.publish(hidden, ticket: ticket)
        }
      }
    }
    /// A picture of the bar as the root page left it, where it sat in the tab controller, and the
    /// controller's size then (a turned device invalidates it).
    private var ghost: (view: UIView, frame: CGRect, size: CGSize)?
    private func keepGhost(of bar: UITabBar, in tabs: UITabBarController) -> Bool {
      ghost?.view.removeFromSuperview()
      ghost = nil
      guard bar.window != nil, !bar.isHidden, bar.alpha > 0.5, bar.bounds.width > 0 else { return false }
      let frame = bar.convert(bar.bounds, to: tabs.view)
      // The screen there, not the bar alone: the bar's glass is drawn from what lies behind it,
      // which a picture of the bar on its own leaves out (it came out see-through).
      guard let picture = tabs.view.resizableSnapshotView(from: frame, afterScreenUpdates: false, withCapInsets: .zero)
      else { return false }
      picture.isUserInteractionEnabled = false
      ghost = (picture, frame, tabs.view.bounds.size)
      return true
    }
    /// Puts the picture on the root page, where the bar sits once the page is in place.
    private func pinGhost(on root: UIViewController, nav: UINavigationController, tabs: UITabBarController) -> UIView? {
      guard let ghost, ghost.size == tabs.view.bounds.size, let page = root.viewIfLoaded else { return nil }
      let origin = tabs.view.convert(CGPoint.zero, from: nav.view)
      ghost.view.frame = ghost.frame.offsetBy(dx: -origin.x, dy: -origin.y)
      page.addSubview(ghost.view)
      return ghost.view
    }
    private func settle() {
      guard let nav = navigationController, let tabs = nav.tabBarController else { return }
      generation &+= 1
      let hidden = nav.topViewController !== nav.viewControllers.first
      if !hidden { tabs.tabBar.alpha = 1 }
      publish(hidden, ticket: generation)
    }
    private func publish(_ hidden: Bool, ticket: Int) {
      DispatchQueue.main.async { [weak self] in
        guard let self, self.generation == ticket else { return }
        self.changed(hidden)
      }
    }
  }
}
