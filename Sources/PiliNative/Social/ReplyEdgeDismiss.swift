import SwiftUI
import UIKit

struct ReplyEdgeDismiss: ViewModifier {
  var standalone = true
  @AppStorage("reply.edgeDismiss") private var enabled = true
  @Environment(\.dismiss) private var dismiss
  func body(content: Content) -> some View {
    if standalone {
      content.background(
        EdgeNavigation(enabled: enabled, back: { dismiss() }).allowsHitTesting(false))
    } else {
      content
    }
  }
}
private struct EdgeNavigation: UIViewControllerRepresentable {
  let enabled: Bool
  var customBack = false
  let back: () -> Void
  func makeUIViewController(context: Context) -> Probe { Probe() }
  func updateUIViewController(_ vc: Probe, context: Context) {
    vc.back = back
    vc.enabled = enabled
    vc.customBack = customBack
    vc.updateIfVisible()
  }
  static func dismantleUIViewController(_ vc: Probe, coordinator: ()) { vc.releaseGestures() }
  final class Probe: UIViewController, UIGestureRecognizerDelegate {
    var enabled = true, customBack = false, back: (() -> Void)?
    private var visible = false
    private weak var installed: UIView?
    private weak var native: UIGestureRecognizer?
    private var previous: Bool?
    private var gestures: [UIScreenEdgePanGestureRecognizer] = []
    override func loadView() {
      view = UIView()
      view.isUserInteractionEnabled = false
    }
    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      visible = true
      updateIfVisible()
    }
    override func viewWillDisappear(_ animated: Bool) {
      visible = false
      releaseGestures()
      super.viewWillDisappear(animated)
    }
    func updateIfVisible() {
      guard visible, let nav = navigationController,
        nav.viewControllers.count > 1 || nav.presentingViewController != nil || nav.parent?.presentingViewController != nil,
        let host = nav.topViewController?.view,
        let v = viewIfLoaded, v.isDescendant(of: host)
      else { return }
      if installed !== host {
        releaseGestures()
        installed = host
        native = nav.viewControllers.count > 1 ? nav.interactivePopGestureRecognizer : nil
        previous = native?.isEnabled
        for edge: UIRectEdge in [.left, .right] {
          let g = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(panned(_:)))
          g.edges = edge
          g.delegate = self
          host.addGestureRecognizer(g)
          gestures.append(g)
        }
      }
      native?.isEnabled = enabled && !customBack && (previous ?? false)
      let nativeEdge =
        (native as? UIScreenEdgePanGestureRecognizer)?.edges
        ?? (host.effectiveUserInterfaceLayoutDirection == .rightToLeft ? .right : .left)
      for g in gestures {
        g.isEnabled = enabled && (native?.isEnabled != true || g.edges != nativeEdge)
      }
    }
    func releaseGestures() {
      for g in gestures { g.view?.removeGestureRecognizer(g) }
      gestures.removeAll()
      if let previous { native?.isEnabled = previous }
      native = nil
      previous = nil
      installed = nil
    }
    @objc private func panned(_ g: UIScreenEdgePanGestureRecognizer) {
      guard enabled, visible, g.state == .ended, let v = g.view,
        g.translation(in: v).x * (g.edges == .right ? -1 : 1) >= 100
      else { return }
      back?()
    }
  }
}

/// Keep the search and its loaded page when Back is pressed during a bulk selection.
struct SelectionCancelBack: ViewModifier {
  let active: Bool
  let cancel: () -> Void
  func body(content: Content) -> some View {
    content
      .navigationBarBackButtonHidden(active)
      .toolbar {
        if active {
          ToolbarItem(placement: .topBarLeading) {
            Button("取消选择", systemImage: "chevron.backward", action: cancel)
          }
        }
      }
      .background {
        if active { EdgeNavigation(enabled: true, customBack: true, back: cancel).allowsHitTesting(false) }
      }
  }
}
