import SwiftUI
import UIKit

// The deployment target is iOS 17. Each wrapper here calls the newer system API where it exists
// (so iOS 18 and iOS 26 keep exactly the behaviour they had) and falls back on older systems.

extension View {
  /// `safeAreaBar` (iOS 26, with the bar's scroll edge effect), or `safeAreaInset` before.
  @ViewBuilder func piliSafeAreaBar<Bar: View>(
    edge: VerticalEdge, spacing: CGFloat? = nil, @ViewBuilder content: () -> Bar
  ) -> some View {
    if #available(iOS 26, *) {
      safeAreaBar(edge: edge, spacing: spacing, content: content)
    } else {
      safeAreaInset(edge: edge, spacing: spacing, content: content)
    }
  }
  /// Focus for the system search field (iOS 18); earlier systems keep their default focus.
  @ViewBuilder func piliSearchFocused(_ focus: FocusState<Bool>.Binding) -> some View {
    if #available(iOS 18, *) { searchFocused(focus) } else { self }
  }
  /// Hides the inline navigation title (`toolbar(removing: .title)` from iOS 18).
  @ViewBuilder func piliRemovingToolbarTitle() -> some View {
    if #available(iOS 18, *) {
      toolbar(removing: .title)
    } else {
      toolbar { ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) } }
    }
  }
  /// The tab bar's minimize-on-scroll behaviour (iOS 26).
  @ViewBuilder func piliTabBarMinimize(onScrollDown: Bool) -> some View {
    if #available(iOS 26, *) {
      tabBarMinimizeBehavior(onScrollDown ? .onScrollDown : .never)
    } else {
      self
    }
  }
}

extension UINavigationController {
  /// The full-width "swipe anywhere to go back" recognizer of iOS 26; nil before.
  var piliContentPopGesture: UIGestureRecognizer? {
    if #available(iOS 26, *) { return interactiveContentPopGestureRecognizer }
    return nil
  }
}

extension UIScrollView {
  func piliStopScrolling() {
    if #available(iOS 17.4, *) { stopScrollingAndZooming() } else { setContentOffset(contentOffset, animated: false) }
  }
}

// MARK: Scroll geometry and phase

/// The parts of SwiftUI's `ScrollGeometry` (iOS 18) the app reads, under the same names.
struct PiliScrollGeometry: Equatable {
  var contentOffset: CGPoint
  var contentSize: CGSize
  var contentInsets: EdgeInsets
  var containerSize: CGSize
  var visibleRect: CGRect
  @available(iOS 18, *)
  init(_ g: ScrollGeometry) {
    contentOffset = g.contentOffset
    contentSize = g.contentSize
    contentInsets = g.contentInsets
    containerSize = g.containerSize
    visibleRect = g.visibleRect
  }
  init(_ s: UIScrollView) {
    let inset = s.adjustedContentInset
    contentOffset = s.contentOffset
    contentSize = s.contentSize
    contentInsets = EdgeInsets(top: inset.top, leading: inset.left, bottom: inset.bottom, trailing: inset.right)
    containerSize = s.bounds.size
    visibleRect = CGRect(origin: s.contentOffset, size: s.bounds.size)
  }
}

/// SwiftUI's `ScrollPhase` (iOS 18), under the same case names.
enum PiliScrollPhase: Equatable {
  case idle, tracking, interacting, decelerating, animating
  var isScrolling: Bool { self != .idle }
  @available(iOS 18, *)
  init(_ p: ScrollPhase) {
    switch p {
    case .idle: self = .idle
    case .tracking: self = .tracking
    case .interacting: self = .interacting
    case .decelerating: self = .decelerating
    case .animating: self = .animating
    @unknown default: self = .idle
    }
  }
}

extension View {
  /// `onScrollGeometryChange` (iOS 18). On iOS 17 the underlying UIScrollView is observed.
  func piliOnScrollGeometryChange<T: Equatable>(
    for type: T.Type, of transform: @escaping (PiliScrollGeometry) -> T,
    action: @escaping (_ old: T, _ new: T) -> Void
  ) -> some View {
    modifier(ScrollGeometryCompat(transform: transform, action: action))
  }
  /// `onScrollPhaseChange` (iOS 18), with the geometry at the change. On iOS 17 the phase is read
  /// from the underlying UIScrollView (dragging, decelerating, or settling after a move).
  func piliOnScrollPhaseChange(
    _ action: @escaping (_ old: PiliScrollPhase, _ new: PiliScrollPhase, _ geometry: PiliScrollGeometry) -> Void
  ) -> some View {
    modifier(ScrollPhaseCompat(action: action))
  }
}

private final class LastValue<T> { var value: T?; init() {} }

private struct ScrollGeometryCompat<T: Equatable>: ViewModifier {
  let transform: (PiliScrollGeometry) -> T
  let action: (T, T) -> Void
  @State private var last = LastValue<T>()
  @ViewBuilder func body(content: Content) -> some View {
    if #available(iOS 18, *) {
      content.onScrollGeometryChange(for: T.self) { transform(PiliScrollGeometry($0)) } action: { action($0, $1) }
    } else {
      content.background(
        LegacyScrollObserver(geometry: { g in
          let value = transform(g)
          if let old = last.value {
            if old != value { last.value = value; action(old, value) }
          } else {
            last.value = value
          }
        }, phase: nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false))
    }
  }
}

private struct ScrollPhaseCompat: ViewModifier {
  let action: (PiliScrollPhase, PiliScrollPhase, PiliScrollGeometry) -> Void
  @ViewBuilder func body(content: Content) -> some View {
    if #available(iOS 18, *) {
      content.onScrollPhaseChange { old, new, context in
        action(PiliScrollPhase(old), PiliScrollPhase(new), PiliScrollGeometry(context.geometry))
      }
    } else {
      content.background(
        LegacyScrollObserver(geometry: nil, phase: action)
          .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false))
    }
  }
}

/// iOS 17: finds the UIScrollView of the ScrollView it sits behind (the scroll view with its
/// frame) and reports its geometry and an inferred scroll phase.
private struct LegacyScrollObserver: UIViewRepresentable {
  let geometry: ((PiliScrollGeometry) -> Void)?
  let phase: ((PiliScrollPhase, PiliScrollPhase, PiliScrollGeometry) -> Void)?
  func makeUIView(context: Context) -> Probe {
    let probe = Probe()
    probe.isUserInteractionEnabled = false
    probe.backgroundColor = .clear
    return probe
  }
  func updateUIView(_ probe: Probe, context: Context) {
    probe.onGeometry = geometry
    probe.onPhase = phase
    probe.attachSoon()
  }
  static func dismantleUIView(_ probe: Probe, coordinator: ()) { probe.detach() }

  final class Probe: UIView {
    var onGeometry: ((PiliScrollGeometry) -> Void)?
    var onPhase: ((PiliScrollPhase, PiliScrollPhase, PiliScrollGeometry) -> Void)?
    private weak var scroll: UIScrollView?
    private var observations: [NSKeyValueObservation] = []
    private var current = PiliScrollPhase.idle
    private var settle: DispatchWorkItem?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window == nil { detach() } else { attachSoon() }
    }
    override func layoutSubviews() {
      super.layoutSubviews()
      if scroll == nil { attachSoon() }
    }
    func attachSoon() {
      guard scroll == nil, window != nil else { return }
      DispatchQueue.main.async { [weak self] in self?.attach() }
    }
    func detach() {
      observations.removeAll()
      settle?.cancel()
      scroll = nil
    }
    private func attach() {
      guard scroll == nil, let window else { return }
      let frame = convert(bounds, to: window)
      guard frame.width > 1, frame.height > 1 else { return }
      var ancestor = superview
      for _ in 0..<6 {
        guard let a = ancestor else { break }
        if let found = Self.search(a, frame: frame, window: window) { bind(found); return }
        ancestor = a.superview
      }
    }
    /// Breadth first, so the shallowest scroll view with this frame wins over nested pages.
    private static func search(_ root: UIView, frame: CGRect, window: UIWindow) -> UIScrollView? {
      var queue: [UIView] = root.subviews
      var depth = 0
      while !queue.isEmpty && depth < 10 {
        var next: [UIView] = []
        for v in queue {
          if let s = v as? UIScrollView {
            let f = s.convert(s.bounds, to: window)
            if abs(f.minX - frame.minX) < 1.5, abs(f.minY - frame.minY) < 1.5,
              abs(f.width - frame.width) < 1.5, abs(f.height - frame.height) < 1.5 { return s }
          }
          next.append(contentsOf: v.subviews)
        }
        queue = next
        depth += 1
      }
      return nil
    }
    private func bind(_ s: UIScrollView) {
      scroll = s
      let changed: (UIScrollView) -> Void = { [weak self] s in
        DispatchQueue.main.async { self?.changed(s) }
      }
      observations = [
        s.observe(\.contentOffset, options: [.new]) { s, _ in changed(s) },
        s.observe(\.contentSize, options: [.new]) { s, _ in changed(s) },
        s.observe(\.bounds, options: [.new]) { s, _ in changed(s) },
      ]
      changed(s)
    }
    private func changed(_ s: UIScrollView) {
      let g = PiliScrollGeometry(s)
      onGeometry?(g)
      guard onPhase != nil else { return }
      let now: PiliScrollPhase =
        s.isDragging ? .interacting : s.isTracking ? .tracking : s.isDecelerating ? .decelerating : .animating
      report(now, g)
      // No callback marks the end of a move, so settle to idle once the offset stops changing.
      settle?.cancel()
      let item = DispatchWorkItem { [weak self, weak s] in
        guard let self, let s else { return }
        if !s.isTracking && !s.isDragging && !s.isDecelerating { self.report(.idle, PiliScrollGeometry(s)) }
      }
      settle = item
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }
    private func report(_ next: PiliScrollPhase, _ g: PiliScrollGeometry) {
      guard next != current else { return }
      let old = current
      current = next
      onPhase?(old, next, g)
    }
  }
}
