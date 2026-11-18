import SwiftUI

/// Observes the pan belonging to the actual vertical scroller the reader touched. The
/// observer never recognizes a gesture itself, and never changes the scroll view's delegate.
struct NavScrollAttachment: UIViewRepresentable {
  let mounted: (UIView) -> Void
  @MainActor static func visible(_ child:UIView,in root:UIView)->Bool {
    guard child.window != nil,child.isDescendant(of:root) else{return false}
    var rect=child.convert(child.bounds,to:root)
    var next:UIView?=child
    while let v=next {
      guard !v.isHidden,v.alpha>0.01,v.isUserInteractionEnabled else{return false}
      if v === root || v.clipsToBounds {rect=rect.intersection(v.convert(v.bounds,to:root))}
      if rect.isNull || rect.width < 1 || rect.height < 1 {return false}
      if v === root {return true};next=v.superview
    }
    return false
  }
  @MainActor static func primaryScroll(in root: UIView) -> UIScrollView? {
    var best: UIScrollView?
    var area: CGFloat = 0
    func visit(_ view: UIView) {
      guard !view.isHidden, view.alpha > 0.01, view.window != nil else { return }
      if let s = view as? UIScrollView, s.isScrollEnabled,
        s.contentSize.width <= s.bounds.width + 2,
        s.alwaysBounceVertical || s.refreshControl != nil || s.contentSize.height > s.bounds.height
      {
        let r = root.bounds.intersection(s.convert(s.bounds, to: root))
        if !r.isNull, r.width * r.height > area,visible(s,in:root) {
          best = s
          area = r.width * r.height
        }
      }
      for child in view.subviews { visit(child) }
    }
    visit(root)
    return best
  }
  let touched: (UIScrollView) -> Void
  let ended: (UIScrollView, CGFloat, CGFloat, Bool) -> Void
  final class TapProbe: UIGestureRecognizer {
    var touched: ((UIView) -> Void)?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
      if let hit = touches.first?.view { touched?(hit) }
      state = .failed
    }
    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
  }
  final class Marker: UIView {
    var mounted: ((UIView) -> Void)?
    var touched: ((UIScrollView) -> Void)?
    var ended: ((UIScrollView, CGFloat, CGFloat, Bool) -> Void)?
    private let probe = TapProbe()
    private weak var host: UIView?, scroll: UIScrollView?
    private var interaction = 0
    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      probe.cancelsTouchesInView = false
      probe.delaysTouchesBegan = false
      probe.delaysTouchesEnded = false
      probe.touched = { [weak self] hit in self?.begin(hit) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      clear()
      if window != nil { DispatchQueue.main.async { [weak self] in self?.install() } }
    }
    func clear() {
      interaction &+= 1
      host?.removeGestureRecognizer(probe)
      host = nil
      scroll?.panGestureRecognizer.removeTarget(self, action: #selector(moved(_:)))
      scroll = nil
    }
    private func install() {
      guard let window else { return }
      var responder: UIResponder? = self
      var view: UIView?
      while let r = responder {
        if let vc = r as? UIViewController {
          if let root = vc.navigationController?.viewControllers.first?.viewIfLoaded,
            isDescendant(of: root)
          {
            view = root
            break
          }
          if view == nil, let v = vc.viewIfLoaded, v.bounds.width > 64, v.bounds.height > 64 {
            view = v
          }
        }
        responder = r.next
      }
      let target = view ?? window
      mounted?(target)
      if host !== target {
        host?.removeGestureRecognizer(probe)
        target.addGestureRecognizer(probe)
        host = target
      }
    }
    private func begin(_ hit: UIView) {
      interaction &+= 1
      var v: UIView? = hit
      while let item = v {
        if let sv = item as? UIScrollView, sv.isScrollEnabled,
          sv.contentSize.height + sv.adjustedContentInset.top + sv.adjustedContentInset.bottom > sv
            .bounds.height + 1,
          sv.contentSize.width <= sv.bounds.width + 2
        {
          if scroll !== sv {
            scroll?.panGestureRecognizer.removeTarget(self, action: #selector(moved(_:)))
            scroll = sv
            sv.panGestureRecognizer.addTarget(self, action: #selector(moved(_:)))
          }
          touched?(sv)
          return
        }
        if item === host { break }
        v = item.superview
      }
    }
    @objc private func moved(_ g: UIPanGestureRecognizer) {
      guard g.state == .ended, let s = scroll, s.panGestureRecognizer === g,
        let window = s.window else { return }
      let distance = g.translation(in: window)
      guard abs(distance.y) > abs(distance.x) else { return }
      let velocity = -g.velocity(in: window).y
      let top = s.contentOffset.y + s.adjustedContentInset.top <= 0.5
      let ticket = interaction
      // Let UIKit finish dispatching the pan before changing the tab's layout.
      DispatchQueue.main.async { [weak self, weak s] in
        guard let self, let s, ticket == self.interaction, s.window != nil,
          self.scroll === s, !s.isTracking, !s.isDragging else { return }
        self.ended?(s, -distance.y, velocity, top)
      }
    }
  }
  func makeUIView(context: Context) -> Marker {
    let v = Marker()
    v.mounted = mounted
    v.touched = touched
    v.ended = ended
    return v
  }
  func updateUIView(_ view: Marker, context: Context) {
    view.mounted = mounted
    view.touched = touched
    view.ended = ended
  }
  static func dismantleUIView(_ view: Marker, coordinator: ()) {
    view.clear()
    view.touched = nil
    view.ended = nil
    view.mounted = nil
  }
}
