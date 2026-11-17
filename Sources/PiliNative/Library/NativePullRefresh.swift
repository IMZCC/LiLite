import SwiftUI
import Observation

/// UIKit exposes neither the arm distance nor the resting position of UIRefreshControl.
/// Observe the touched scroll view's own pan without taking its delegate or intercepting row taps.
struct NativePullRefresh: ViewModifier {
  @MainActor static func repeatTab(on scroll:UIScrollView) -> Bool { PullMarker.Marker.repeatTab(on:scroll) }
  let refresh: @MainActor () async -> Void
  @AppStorage(InterfaceInteraction.displacement) private var preference = 20.0
  @State private var model = PullState()
  func body(content: Content) -> some View {
    let height = InterfaceInteraction.distance(preference)
    content.scrollBounceBehavior(.always, axes: .vertical)
      .background {
        PullMarker(
          repeatTab: { model.start(refresh) }, changed: { distance in model.drag(distance, height: height) },
          released: { distance in model.release(distance, height: height, action: refresh) })
      }
      .overlay(alignment: .top) {
        PullIndicator(model: model, height: height)
      }
      .accessibilityAction(named: "刷新") { model.start(refresh) }
      .onDisappear { model.stop() }
  }
  @MainActor @Observable final class PullState {
    var progress = 0.0
    var working = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var stamp = UUID()
    func drag(_ distance: Double, height: Double) {
      guard !working else { return }
      let next = min(1, max(0, distance / InterfaceInteraction.refreshThreshold(height)))
      if next == 0 || next == 1 || abs(next - progress) > 0.015 {
        if progress != next { progress = next }
      }
    }
    func release(_ distance: Double, height: Double, action: @escaping @MainActor () async -> Void)
    {
      guard !working else { return }
      if distance >= InterfaceInteraction.refreshThreshold(height) {
        start(action)
      } else {
        progress = 0
      }
    }
    func start(_ action: @escaping @MainActor () async -> Void) {
      guard !working else { return }
      working = true
      progress = 0
      let id = UUID()
      stamp = id
      task = Task {
        await action()
        if !Task.isCancelled, stamp == id {
          working = false
          task = nil
        }
      }
    }
    func stop() {
      stamp = UUID()
      task?.cancel()
      task = nil
      working = false
      progress = 0
    }
  }
}
private struct PullIndicator: View {
  let model: NativePullRefresh.PullState, height: Double
  var body: some View {
    if model.working || model.progress > 0 {
      ZStack {
        Circle().fill(.regularMaterial)
        if model.working { ProgressView().controlSize(.small) }
        else {
          Circle().trim(from: 0, to: model.progress)
            .stroke(.tint, style: .init(lineWidth: 2.6, lineCap: .round))
            .rotationEffect(.degrees(-90)).padding(7)
        }
      }.frame(width: 32, height: 32)
        .offset(y: model.working ? height : (height + 32) * model.progress - 32)
        .allowsHitTesting(false).accessibilityHidden(!model.working).accessibilityLabel("正在刷新")
    }
  }
}
extension View {
  func piliRefreshable(_ handler: @escaping @MainActor () async -> Void) -> some View {
    modifier(NativePullRefresh(refresh: handler))
  }
}
private struct PullMarker: UIViewRepresentable {
  let repeatTab: () -> Void
  let changed: (Double) -> Void, released: (Double) -> Void
  final class Watch: UIGestureRecognizer {
    weak var marker: Marker?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
      if let touch = touches.first { marker?.touch(touch) }
      state = .failed
    }
    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
  }
  final class Marker: UIView {
    var changed: ((Double) -> Void)?, released: ((Double) -> Void)?
    private static let owners = NSMapTable<UIScrollView, Marker>.weakToWeakObjects()
    var repeated: (() -> Void)?
    static func repeatTab(on scroll:UIScrollView) -> Bool {
      guard let m=owners.object(forKey:scroll), m.window != nil, m.scroll === scroll, let f=m.repeated else { return false }
      f(); return true
    }
    private let watch = Watch()
    private weak var host: UIView?, scroll: UIScrollView?
    private var possible = false, pull = 0.0
    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      watch.marker = self
      watch.cancelsTouchesInView = false
      watch.delaysTouchesBegan = false
      watch.delaysTouchesEnded = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      clear()
      if window != nil { DispatchQueue.main.async { [weak self] in self?.mount() } }
    }
    func mount() {
      guard let window, host == nil else { return }
      var r: UIResponder? = self
      while let value = r {
        if let c = value as? UIViewController, let v = c.viewIfLoaded, isDescendant(of: v),
          v.bounds.width > 30
        {
          host = v
          v.addGestureRecognizer(watch)
          findVisibleScroll()
          return
        }
        r = value.next
      }
      host = window
      window.addGestureRecognizer(watch)
      findVisibleScroll()
    }
    private func findVisibleScroll() {
      guard let window, scroll == nil, bounds.width > 1, bounds.height > 1 else { return }
      let center = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: window)
      if let hit = window.hitTest(center, with: nil) { attach(hit) }
    }
    override func layoutSubviews() {
      super.layoutSubviews()
      findVisibleScroll()
    }
    func clear() {
      if let s = scroll, Self.owners.object(forKey: s) === self {
        Self.owners.removeObject(forKey: s)
      }
      host?.removeGestureRecognizer(watch)
      host = nil
      scroll?.panGestureRecognizer.removeTarget(self, action: #selector(moved(_:)))
      scroll = nil
      possible = false
      pull = 0
    }
    func touch(_ touch: UITouch) {
      guard window != nil, bounds.contains(touch.location(in: self)), let hit = touch.view else {
        return
      }
      attach(hit)
    }
    private func attach(_ hit: UIView) {
      guard let host, hit.isDescendant(of: host) else { return }
      var a: UIView? = self
      while let v = a {
        if v.isHidden || v.alpha <= 0.01 { return }
        a = v.superview
      }
      a = hit
      while let v = a {
        if let s = v as? UIScrollView, s.isScrollEnabled, s.zoomScale <= s.minimumZoomScale + 0.01,
          s.contentSize.width <= s.bounds.width + 2, !(s is UITextView),
          s.bounds.width >= bounds.width * 0.6, s.bounds.height >= min(80, bounds.height * 0.5)
        {
          if let prior = Self.owners.object(forKey: s), prior !== self,
            prior.window != nil, !prior.isHidden,
            prior.bounds.width * prior.bounds.height + 2 < bounds.width * bounds.height
          {
            return
          }
          Self.owners.setObject(self, forKey: s)
          scroll?.panGestureRecognizer.removeTarget(self, action: #selector(moved(_:)))
          scroll = s
          possible = s.contentOffset.y + s.adjustedContentInset.top <= 1
          pull = 0
          s.panGestureRecognizer.addTarget(self, action: #selector(moved(_:)))
          return
        }
        if v === host { return }
        a = v.superview
      }
    }
    @objc func moved(_ gesture: UIPanGestureRecognizer) {
      guard let s = scroll, gesture === s.panGestureRecognizer,
        Self.owners.object(forKey: s) === self
      else { return }
      let t = gesture.translation(in: self)
      if gesture.state == .began {
        possible = s.contentOffset.y + s.adjustedContentInset.top <= 1 && t.y >= 0
      }
      guard possible else { return }
      switch gesture.state {
      case .began, .changed, .ended:
        pull =
          abs(t.y) >= abs(t.x)
            && (gesture.state == .ended || s.contentOffset.y + s.adjustedContentInset.top <= 1)
          ? max(0, t.y) : 0
        if gesture.state == .ended {
          possible = false
          released?(pull)
        } else {
          changed?(pull)
        }
      case .cancelled, .failed:
        possible = false
        released?(0)
      default: break
      }
    }
  }
  func makeUIView(context: Context) -> Marker { Marker() }
  func updateUIView(_ v: Marker, context: Context) {
    v.repeated = repeatTab
    v.changed = changed
    v.released = released
    v.mount()
  }
  static func dismantleUIView(_ v: Marker, coordinator: ()) {
    v.clear()
    v.repeated = nil
    v.changed = nil
    v.released = nil
  }
}
