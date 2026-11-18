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
      if transition.initiallyInteractive {
        // Changing SwiftUI toolbar visibility resizes both hosting controllers and their
        // pagers. Keep that layout stable until the system finishes or cancels the swipe.
        transition.animate(alongsideTransition: nil) { [weak self, weak nav] _ in
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
