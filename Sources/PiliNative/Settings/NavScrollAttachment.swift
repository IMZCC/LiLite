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
    let fullArea = root.bounds.width * root.bounds.height
    func visit(_ view: UIView) {
      guard area < fullArea, !view.isHidden, view.alpha > 0.01, view.window != nil else { return }
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
  let change: (CGFloat, Bool, UIScrollView) -> Void
  /// Called when the finger lifts, with the vertical velocity (points/s, positive = scrolling down).
  var ended: ((CGFloat) -> Void)? = nil
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
    var handle: ((CGFloat, Bool, UIScrollView) -> Void)?
    var release: ((CGFloat) -> Void)?
    private let probe = TapProbe()
    private weak var host: UIView?, scroll: UIScrollView?
    /// The tab's root page. Its content scroll view drives the tab bar's minimize-on-scroll, and
    /// the system's own pick is the outermost scroller, which on a page with a horizontal pager
    /// (the home channels) never scrolls vertically.
    private weak var owner: UIViewController?
    private var previous: CGFloat = 0
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
          if let first = vc.navigationController?.viewControllers.first, let root = first.viewIfLoaded,
            isDescendant(of: root)
          {
            view = root
            owner = first
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
      var v: UIView? = hit
      while let item = v {
        if let sv = item as? UIScrollView, sv.isScrollEnabled,
          sv.contentSize.height + sv.adjustedContentInset.top + sv.adjustedContentInset.bottom > sv
            .bounds.height + 1,
          sv.contentSize.width <= sv.bounds.width + 2
        {
          scroll?.panGestureRecognizer.removeTarget(self, action: #selector(moved(_:)))
          scroll = sv
          previous = 0
          sv.panGestureRecognizer.addTarget(self, action: #selector(moved(_:)))
          // Only a page-wide list, not a side column (the 动态 UP 主 rail).
          if let owner, let host, sv.bounds.width >= host.bounds.width * 0.5,
            owner.contentScrollView(for: .bottom) !== sv
          {
            owner.setContentScrollView(sv, for: .bottom)
          }
          return
        }
        if item === host { break }
        v = item.superview
      }
    }
    @objc private func moved(_ g: UIPanGestureRecognizer) {
      guard let s = scroll, s.panGestureRecognizer === g else { return }
      let point = g.translation(in: s)
      if g.state == .began { previous = 0 }
      if g.state == .ended || g.state == .cancelled {
        release?(-g.velocity(in: s).y)
        return
      }
      guard g.state == .began || g.state == .changed else { return }
      let v = -point.y
      let delta = v - previous
      previous = v
      guard abs(point.y) >= abs(point.x) else { return }
      handle?(delta, s.contentOffset.y + s.adjustedContentInset.top <= 0.5 && delta <= 0, s)
    }
  }
  func makeUIView(context: Context) -> Marker {
    let v = Marker()
    v.mounted = mounted
    v.handle = change
    v.release = ended
    return v
  }
  func updateUIView(_ view: Marker, context: Context) {
    view.mounted = mounted
    view.handle = change
    view.release = ended
  }
  static func dismantleUIView(_ view: Marker, coordinator: ()) {
    view.clear()
    view.handle = nil
    view.release = nil
    view.mounted = nil
  }
}
