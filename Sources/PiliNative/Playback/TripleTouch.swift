import SwiftUI
import UIKit

/// A real control receives touch-up, drag-out and scrolling cancellation separately.
struct TripleTouch: UIViewRepresentable {
  let owner: String, perform: (PlayerKeyEffect) -> Void
  final class Surface: UIControl {
    let ring = CAShapeLayer()
    var action: ((PlayerKeyEffect) -> Void)?, initial = CGPoint.zero, scope = ""
    private var keys = PlayerKeySequence(), job: Task<Void, Never>?
    private var now: Int { Int(ProcessInfo.processInfo.systemUptime * 1000) }
    private let policy = PlayerKeyScope(
      live: false, social: true, relation: false, send: false, full: false, capture: false,
      step: false, ready: false, canPlay: false, locked: false)
    override init(frame: CGRect) {
      super.init(frame: frame)
      isAccessibilityElement = false
      isMultipleTouchEnabled = false
      ring.strokeColor = UIColor.systemPink.cgColor
      ring.fillColor = UIColor.clear.cgColor
      ring.lineWidth = 2
      ring.lineCap = .round
      ring.isHidden = true
      layer.addSublayer(ring)
      NotificationCenter.default.addObserver(
        self, selector: #selector(abort), name: UIApplication.willResignActiveNotification,
        object: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func layoutSubviews() {
      super.layoutSubviews()
      ring.frame = bounds
      ring.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: 5).cgPath
    }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
      abort()
      initial = touch.location(in: self)
      _ = keys.down(.q, at: now, scope: policy)
      schedule()
      return true
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
      let p = touch.location(in: self)
      if !bounds.contains(p) || hypot(p.x - initial.x, p.y - initial.y) > 12 {
        abort()
        return false
      }
      return true
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
      ring.removeAllAnimations()
      ring.isHidden = true
      job?.cancel()
      job = nil
      guard let touch, bounds.contains(touch.location(in: self)) else {
        abort()
        return
      }
      let out = keys.up(.q, at: now, playing: false)
      for e in out { action?(e) }
    }
    override func cancelTracking(with event: UIEvent?) { abort() }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window == nil { abort() }
    }
    @objc func abort() {
      ring.removeAllAnimations()
      ring.isHidden = true
      job?.cancel()
      job = nil
      _ = keys.cancel()
    }
    private func schedule() {
      guard let due = keys.delay else { return }
      job = Task { @MainActor [weak self] in
        guard let self else { return }
        do { try await Task.sleep(for: .milliseconds(max(1, due - now))) } catch { return }
        guard window?.windowScene?.activationState == .foregroundActive else {
          abort()
          return
        }
        let actions = keys.pulse(now, playing: false)
        for e in actions {
          if e == .armTriple {
            ring.isHidden = false
            if !UIAccessibility.isReduceMotionEnabled {
              let anim = CABasicAnimation(keyPath: "strokeEnd")
              anim.fromValue = 0
              anim.toValue = 1
              anim.duration = 1.2
              ring.add(anim, forKey: "hold")
            }
          }
          if e == .triple { ring.isHidden = true }
          action?(e)
        }
        schedule()
      }
    }
  }
  func makeUIView(context: Context) -> Surface { Surface() }
  func updateUIView(_ v: Surface, context: Context) {
    if v.scope != owner {
      v.abort()
      v.scope = owner
    }
    v.action = perform
  }
  static func dismantleUIView(_ v: Surface, coordinator: ()) {
    v.abort()
    v.action = nil
  }
}
