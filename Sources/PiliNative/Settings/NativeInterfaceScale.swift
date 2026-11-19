import SwiftUI

/// Give the app a correspondingly larger/smaller layout proposal before transforming the result.
/// This preserves reflow, hit-testing and UIKit view coordinate conversion; no screen/window transform.
private struct NativePixels: EnvironmentKey { static let defaultValue: CGFloat? = nil }
extension EnvironmentValues {
  fileprivate var piliPixels: CGFloat? {
    get { self[NativePixels.self] }
    set { self[NativePixels.self] = newValue }
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
  func body(content: Content) -> some View {
    let factor = InterfaceInteraction.interfaceScale(value)
    let physical = devicePixels ?? pixels
    InterfaceLayout(factor: factor) {
      content.environment(\.piliPixels, physical).environment(\.displayScale, physical * factor)
        // Presented pages are never under the video detail's overlaid header.
        .environment(\.panelTopInset, 0).environment(\.panelScroll, nil).environment(\.panelBottomInset, 0)
        .scaleEffect(factor, anchor: .center)
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
