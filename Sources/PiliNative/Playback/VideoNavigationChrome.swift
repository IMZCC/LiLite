import SwiftUI
import UIKit

/// Keep the media and its UI alive while UIKit is deciding whether an interactive pop commits.
@MainActor private final class VideoPageDeparture {
  weak var navigation: UINavigationController?
  private var generation = 0

  func appeared() { generation &+= 1 }

  func leave(_ action: @escaping () -> Void) {
    generation &+= 1
    let ticket = generation
    let finish = {
      DispatchQueue.main.async {
        guard self.generation == ticket else { return }
        action()
      }
    }
    if let transition = navigation?.transitionCoordinator {
      if transition.animate(alongsideTransition: nil, completion: { context in
        if !context.isCancelled { finish() }
      }) { return }
      if transition.isCancelled { return }
    }
    finish()
  }
}

private struct VideoPageNavigation: ViewModifier {
  let stopOnDisappear: Bool
  let leave: () -> Void
  @State private var departure = VideoPageDeparture()
  func body(content: Content) -> some View {
    content.background { VideoNavigationChrome(departure: departure).frame(width: 0, height: 0) }
      .onAppear { departure.appeared() }
      .onDisappear { if stopOnDisappear { departure.leave(leave) } }
  }
}

extension View {
  func videoPageNavigation(stopOnDisappear: Bool, leave: @escaping () -> Void) -> some View {
    modifier(VideoPageNavigation(stopOnDisappear: stopOnDisappear, leave: leave))
  }
}

/// The player supplies its own back button. Re-enable the navigation controller's built-in
/// edge interaction for this page so UIKit owns the animation, its velocity and cancellation.
private struct VideoNavigationChrome: UIViewControllerRepresentable {
  let departure: VideoPageDeparture
  func makeUIViewController(context: Context) -> Probe { Probe() }
  func updateUIViewController(_ probe: Probe, context: Context) {
    probe.departure = departure
    probe.updateIfVisible()
  }
  static func dismantleUIViewController(_ probe: Probe, coordinator: ()) { probe.retire() }

  final class Probe: UIViewController, UIGestureRecognizerDelegate {
    fileprivate weak var departure: VideoPageDeparture?
    private weak var navigation: UINavigationController?
    private weak var owner: UIViewController?
    private weak var previousDelegate: UIGestureRecognizerDelegate?
    private var saved: (bar: Bool, edge: Bool, content: Bool?)?
    private var visible = false

    override func loadView() {
      view = UIView()
      view.isUserInteractionEnabled = false
      view.accessibilityElementsHidden = true
    }
    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      visible = true
      updateIfVisible()
    }
    override func viewWillDisappear(_ animated: Bool) {
      super.viewWillDisappear(animated)
      visible = false
      retire()
    }
    func updateIfVisible() {
      guard visible, let nav = navigationController, nav.viewControllers.count > 1,
        let top = nav.topViewController, let host = top.viewIfLoaded,
        viewIfLoaded?.isDescendant(of: host) == true,
        let edge = nav.interactivePopGestureRecognizer else { return }
      departure?.navigation = nav
      if navigation !== nav || saved == nil {
        restore()
        navigation = nav
        owner = top
        saved = (nav.navigationBar.isUserInteractionEnabled, edge.isEnabled, nav.interactiveContentPopGestureRecognizer?.isEnabled)
      }
      guard nav.transitionCoordinator == nil || edge.delegate !== self else { return }
      if edge.delegate !== self {
        previousDelegate = edge.delegate
        edge.delegate = self
      }
      if !edge.isEnabled { edge.isEnabled = true }
      if nav.interactiveContentPopGestureRecognizer?.isEnabled == true {
        nav.interactiveContentPopGestureRecognizer?.isEnabled = false
      }
      nav.navigationBar.isUserInteractionEnabled = false
    }
    func retire() {
      if let transition = navigation?.transitionCoordinator, transition.isInteractive,
        transition.animate(alongsideTransition: nil, completion: { context in
          if !context.isCancelled || !self.visible { self.restore() }
        }) { return }
      if let edge = navigation?.interactivePopGestureRecognizer,
        edge.state == .began || edge.state == .changed { return }
      restore()
    }
    override func viewDidDisappear(_ animated: Bool) {
      super.viewDidDisappear(animated)
      restore()
    }
    private func restore() {
      guard let nav = navigation, let saved else { return }
      let edge = nav.interactivePopGestureRecognizer
      if edge?.delegate === self {
        edge?.delegate = previousDelegate
        edge?.isEnabled = saved.edge
      }
      if !(edge?.delegate is Probe) {
        nav.navigationBar.isUserInteractionEnabled = saved.bar
        if let content = saved.content { nav.interactiveContentPopGestureRecognizer?.isEnabled = content }
      }
      self.saved = nil
      previousDelegate = nil
      owner = nil
      navigation = nil
    }
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
      guard visible, let nav = navigation, let owner, recognizer === nav.interactivePopGestureRecognizer,
        nav.viewControllers.count > 1, nav.topViewController === owner, nav.transitionCoordinator == nil,
        nav.presentedViewController == nil, owner.presentedViewController == nil else { return false }
      return true
    }
    override func responds(to selector: Selector!) -> Bool {
      super.responds(to: selector) || previousDelegate?.responds(to: selector) == true
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
      if previousDelegate?.responds(to: selector) == true { return previousDelegate }
      return super.forwardingTarget(for: selector)
    }
  }
}
