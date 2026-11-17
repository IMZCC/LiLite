import UIKit

/// Customizes only the return from overscroll. Normal scrolling/deceleration and row taps stay in UIKit.
@MainActor final class ScrollRebound: NSObject {
  private final class Watch: UIGestureRecognizer {
    weak var owner: ScrollRebound?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { if let t = touches.first { owner?.touch(t) }; state = .failed }
    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
  }
  private weak var host: UIView?, scroll: UIScrollView?
  private var watch: Watch?
  private var link: CADisplayLink?
  private var initial = CGPoint.zero, velocity = CGPoint.zero, target = CGPoint.zero
  private var activeX = false, activeY = false, began = 0.0
  private var config = ScrollSpring(ScrollSpring.standard)!
  init(host: UIView) {
    self.host = host; super.init()
    let w = Watch(target: nil, action: nil)
    w.cancelsTouchesInView = false; w.delaysTouchesBegan = false; w.delaysTouchesEnded = false
    w.owner = self; host.addGestureRecognizer(w); watch = w
  }
  private func touch(_ t: UITouch) {
    stop()
    scroll?.panGestureRecognizer.removeTarget(self, action: #selector(moved(_:)))
    scroll = nil
    guard !UIAccessibility.isReduceMotionEnabled, let setting = UserDefaults.standard.array(forKey: ScrollSpring.key) as? [Double],
      setting != ScrollSpring.standard, let s = ScrollSpring(setting) else { return }
    config = s
    var next = t.view
    while let v = next, v !== host {
      if let sc = v as? UIScrollView, sc.isScrollEnabled, sc.bounces, !(sc is UITextView),
        sc.zoomScale <= sc.minimumZoomScale + 0.01 {
        scroll = sc; sc.panGestureRecognizer.addTarget(self, action: #selector(moved(_:))); return
      }
      next = v.superview
    }
  }
  @objc private func moved(_ pan: UIPanGestureRecognizer) {
    guard pan.state == .ended, let sc = scroll, sc.window != nil, !sc.isZooming, sc.refreshControl?.isRefreshing != true else { return }
    let speed = pan.velocity(in: sc)
    DispatchQueue.main.async { [weak self, weak sc] in
      guard let self, let sc, self.scroll === sc, !sc.isTracking, !sc.isDragging else { return }
      let p = sc.contentOffset, inset = sc.adjustedContentInset
      let minX = -inset.left, minY = -inset.top
      self.target = CGPoint(x: min(max(p.x, minX), max(minX, sc.contentSize.width - sc.bounds.width + inset.right)),
                            y: min(max(p.y, minY), max(minY, sc.contentSize.height - sc.bounds.height + inset.bottom)))
      self.initial = CGPoint(x: p.x - self.target.x, y: p.y - self.target.y)
      self.activeX = abs(self.initial.x) > 0.6; self.activeY = abs(self.initial.y) > 0.6
      guard self.activeX || self.activeY else { return }
      self.velocity = CGPoint(x: min(640, max(-640, -speed.x)), y: min(640, max(-640, -speed.y)))
      if #available(iOS 17.4, *) { sc.stopScrollingAndZooming() } else { sc.setContentOffset(p, animated: false) }
      self.began = CACurrentMediaTime(); let link = CADisplayLink(target: self, selector: #selector(self.tick))
      self.link = link; link.add(to: .main, forMode: .common)
    }
  }
  @objc private func tick() {
    guard let sc = scroll, sc.window != nil, !sc.isDragging, !sc.isTracking, !sc.isZooming, !UIAccessibility.isReduceMotionEnabled else { stop(); return }
    let elapsed = CACurrentMediaTime()-began
    let a = config.state(offset: initial.x, velocity: velocity.x, after: elapsed)
    let b = config.state(offset: initial.y, velocity: velocity.y, after: elapsed)
    let done = elapsed > 3 || ((!activeX || (abs(a.0) < 0.25 && abs(a.1) < 2)) && (!activeY || (abs(b.0) < 0.25 && abs(b.1) < 2)))
    let pos = CGPoint(x: activeX ? target.x + (done ? 0 : a.0) : sc.contentOffset.x, y: activeY ? target.y + (done ? 0 : b.0) : sc.contentOffset.y)
    sc.setContentOffset(pos, animated: false)
    if done { stop() }
  }
  private func stop() { link?.invalidate(); link = nil }
}
