import SwiftUI
import UIKit

/// Give the app a correspondingly larger/smaller layout proposal before transforming the result.
/// This preserves reflow, hit-testing and UIKit view coordinate conversion; no screen/window transform.
private struct NativePixels: EnvironmentKey { static let defaultValue: CGFloat? = nil }
private struct InterfaceScaled: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
  fileprivate var piliPixels: CGFloat? {
    get { self[NativePixels.self] }
    set { self[NativePixels.self] = newValue }
  }
  /// The page is drawn scaled. The system's reserved regions (the fold, the camera housing) are
  /// then reported for the unscaled layout, so they no longer line up with what is on screen.
  var interfaceScaled: Bool {
    get { self[InterfaceScaled.self] }
    set { self[InterfaceScaled.self] = newValue }
  }
}
private struct InterfaceLayout: Layout {
  let factor: CGFloat
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let content = subviews.first else { return .zero }
    let child = content.sizeThatFits(
      .init(
        width: proposal.width.flatMap { $0.isFinite ? max(0, $0 / factor) : nil },
        height: proposal.height.flatMap { $0.isFinite ? max(0, $0 / factor) : nil }))
    return .init(width: child.width * factor, height: child.height * factor)
  }
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    subviews.first?.place(
      at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
      proposal: .init(width: bounds.width / factor, height: bounds.height / factor))
  }
}
struct NativeInterfaceScale: ViewModifier {
  @AppStorage(InterfaceInteraction.scale) private var value = 1.0
  @Environment(\.displayScale) private var pixels
  @Environment(\.piliPixels) private var devicePixels
  @State private var insets = ScaledSafeArea.windowInsets()
  func body(content: Content) -> some View {
    let factor = InterfaceInteraction.interfaceScale(value)
    let physical = devicePixels ?? pixels
    // Scaled, the page is laid out larger (or smaller) than the screen around its centre, and
    // SwiftUI measured its safe area against that oversized frame: shrunk, every page took
    // hundreds of points of status bar and home indicator, pushing the home feed off the screen.
    // So it gets the screen's own insets instead, converted to its points.
    let scaled = factor == 1 ? EdgeInsets() : EdgeInsets(
      top: insets.top / factor, leading: insets.leading / factor,
      bottom: insets.bottom / factor, trailing: insets.trailing / factor)
    InterfaceLayout(factor: factor) {
      content.environment(\.piliPixels, physical).environment(\.displayScale, physical * factor)
        // Presented pages are never under the video detail's overlaid header.
        .environment(\.panelTopInset, 0).environment(\.panelScroll, nil).environment(\.panelBottomInset, 0)
        .environment(\.interfaceScaled, factor != 1)
        .safeAreaPadding(scaled)
        .scaleEffect(factor, anchor: .center)
    }
    .ignoresSafeArea(factor == 1 ? [] : .container)
    .background {
      if factor != 1 {
        ScaledSafeArea { insets = $0 }.allowsHitTesting(false).accessibilityHidden(true)
      }
    }
  }
}

/// The screen's safe area (status bar, home indicator; never the keyboard) over the unscaled
/// page, in screen points.
private struct ScaledSafeArea: UIViewRepresentable {
  let change: (EdgeInsets) -> Void
  @MainActor static func windowInsets() -> EdgeInsets {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    guard let s = (scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first)?.safeAreaInsets
    else { return EdgeInsets() }
    return EdgeInsets(top: s.top, leading: s.left, bottom: s.bottom, trailing: s.right)
  }
  func makeUIView(context: Context) -> Probe {
    let view = Probe()
    view.change = change
    return view
  }
  func updateUIView(_ view: Probe, context: Context) { view.change = change }
  final class Probe: UIView {
    var change: ((EdgeInsets) -> Void)?
    private var last: EdgeInsets?
    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false; backgroundColor = .clear
    }
    required init?(coder: NSCoder) { nil }
    override func didMoveToWindow() { super.didMoveToWindow(); report() }
    override func layoutSubviews() { super.layoutSubviews(); report() }
    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); report() }
    private func report() {
      guard let window, bounds.width > 0, bounds.height > 0 else { return }
      let safe = convert(window.safeAreaLayoutGuide.layoutFrame, from: window)
      let left = max(0, safe.minX - bounds.minX), right = max(0, bounds.maxX - safe.maxX)
      let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
      let next = EdgeInsets(
        top: max(0, safe.minY - bounds.minY), leading: rtl ? right : left,
        bottom: max(0, bounds.maxY - safe.maxY), trailing: rtl ? left : right)
      guard next != last else { return }
      last = next
      DispatchQueue.main.async { [weak self] in self?.change?(next) }
    }
  }
}
extension View {
  func piliSheet<Item: Identifiable, Destination: View>(
    item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
    @ViewBuilder content: @escaping (Item) -> Destination
  ) -> some View {
    sheet(item: item, onDismiss: onDismiss) { item in content(item).modifier(NativeInterfaceScale())
    }
  }
  func piliSheet<Destination: View>(
    isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
    @ViewBuilder content: @escaping () -> Destination
  ) -> some View {
    sheet(isPresented: isPresented, onDismiss: onDismiss) {
      content().modifier(NativeInterfaceScale())
    }
  }
  func piliFullScreenCover<Item: Identifiable, Destination: View>(
    item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
    @ViewBuilder content: @escaping (Item) -> Destination
  ) -> some View {
    fullScreenCover(item: item, onDismiss: onDismiss) { item in
      content(item).modifier(NativeInterfaceScale())
    }
  }
  func piliFullScreenCover<Destination: View>(
    isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
    @ViewBuilder content: @escaping () -> Destination
  ) -> some View {
    fullScreenCover(isPresented: isPresented, onDismiss: onDismiss) {
      content().modifier(NativeInterfaceScale())
    }
  }
}
