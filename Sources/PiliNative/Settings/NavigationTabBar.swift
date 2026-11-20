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
      if leavingRoot { keepGhost(of: bar, in: tabs) }
      if !hide, let ghost = takeGhost(in: tabs) {
        // Back to the root (a swipe or a tap): the bar the root page left with comes back with
        // it — a picture of it, over where it sat, fading and sliding in as the page does and
        // following the finger. The real bar's hidden state (SwiftUI's toolbar, which resizes
        // both pages) changes only once the transition has finished, under the picture.
        let lead: CGFloat = tabs.view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? 1 : -1
        ghost.alpha = 0
        ghost.transform = CGAffineTransform(translationX: lead * tabs.view.bounds.width * 0.3, y: 0)
        tabs.view.addSubview(ghost)
        transition.animate(alongsideTransition: { _ in
          ghost.alpha = 1
          ghost.transform = .identity
        }) { [weak self, weak nav] context in
          guard let self, let nav, self.generation == ticket else { ghost.removeFromSuperview(); return }
          let hidden = nav.topViewController !== nav.viewControllers.first
          guard !hidden, !context.isCancelled else {
            ghost.removeFromSuperview()
            self.publish(true, ticket: ticket)
            return
          }
          bar.alpha = 1
          if #available(iOS 18, *) { tabs.setTabBarHidden(false, animated: false) }
          self.changed(false)
          // Lift the picture once the real bar is drawn in its place.
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { ghost.removeFromSuperview() }
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
    private func keepGhost(of bar: UITabBar, in tabs: UITabBarController) {
      guard bar.window != nil, !bar.isHidden, bar.alpha > 0.5, bar.bounds.width > 0,
        let picture = bar.snapshotView(afterScreenUpdates: false) else { ghost = nil; return }
      picture.isUserInteractionEnabled = false
      ghost = (picture, bar.convert(bar.bounds, to: tabs.view), tabs.view.bounds.size)
    }
    private func takeGhost(in tabs: UITabBarController) -> UIView? {
      defer { ghost = nil }
      guard let ghost, ghost.size == tabs.view.bounds.size else { return nil }
      ghost.view.transform = .identity
      ghost.view.frame = ghost.frame
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
