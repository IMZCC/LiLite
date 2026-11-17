import Observation
import SwiftUI

/// Header collapse for pages whose content scrolls in its own list (the original client's
/// NestedScrollView headers): scrolling the content down folds the header away, pulling down at
/// the top brings it back. Only `CollapsibleHeader` observes the state, so scrolling never
/// re-renders the page itself.
@MainActor @Observable final class ScrollCollapse {
  private(set) var collapsed = false
  @ObservationIgnored private var travel: CGFloat = 0
  @ObservationIgnored var enabled = true
  @ObservationIgnored private var changedAt: TimeInterval = 0
  /// Content offset of the page's list moved from `old` to `new` (0 = at the top).
  func scrolled(from old: CGFloat, to new: CGFloat) {
    // Folding resizes the list, and short content then clamps back to the top; ignore the
    // offsets produced by our own animation so the header never bounces in and out.
    guard ProcessInfo.processInfo.systemUptime - changedAt > 0.6 else { return }
    if new <= 1 {
      travel = 0
      set(false)
      return
    }
    let delta = new - old
    travel = delta > 0 ? max(0, travel) + delta : min(0, travel) + delta
    if enabled, travel > 36 { set(true) }
  }
  func expand() { travel = 0; set(false) }
  private func set(_ value: Bool) {
    guard collapsed != value else { return }
    changedAt = ProcessInfo.processInfo.systemUptime
    withAnimation(.smooth(duration: 0.34)) { collapsed = value }
  }
}

private struct ScrollCollapseKey: EnvironmentKey {
  static let defaultValue: ScrollCollapse? = nil
}
private struct PanelTopInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct PanelScrollKey: EnvironmentKey {
  static let defaultValue: (@MainActor (CGFloat) -> Void)? = nil
}
extension EnvironmentValues {
  var scrollCollapse: ScrollCollapse? {
    get { self[ScrollCollapseKey.self] }
    set { self[ScrollCollapseKey.self] = newValue }
  }
  /// Height of a header laid over a page's lists (the video detail player and tabs).
  var panelTopInset: CGFloat {
    get { self[PanelTopInsetKey.self] }
    set { self[PanelTopInsetKey.self] = newValue }
  }
  /// Receives the scroll offset of the visible list under such a header.
  var panelScroll: (@MainActor (CGFloat) -> Void)? {
    get { self[PanelScrollKey.self] }
    set { self[PanelScrollKey.self] = newValue }
  }
}
extension View {
  /// Lists inside this view that call `reportsScrollCollapse()` drive `state`.
  func scrollCollapse(_ state: ScrollCollapse) -> some View {
    environment(\.scrollCollapse, state)
  }
  /// Apply to a vertical `List`/`ScrollView` that may sit under a collapsible header.
  func reportsScrollCollapse() -> some View { modifier(ReportsScrollCollapse()) }
}
private struct ReportsScrollCollapse: ViewModifier {
  @Environment(\.scrollCollapse) private var state
  @Environment(\.panelTopInset) private var inset
  @Environment(\.panelScroll) private var panel
  func body(content: Content) -> some View {
    content
      // Pages pushed or presented from inside this list are not under the header.
      .environment(\.panelTopInset, 0).environment(\.panelScroll, nil)
      // Only this list starts below an overlaid header; nested horizontal scrollers do not.
      .safeAreaPadding(.top, inset)
      .onScrollGeometryChange(for: CGFloat.self) { g in
        g.contentOffset.y + g.contentInsets.top
      } action: { old, new in
        state?.scrolled(from: old, to: new)
        panel?(new)
      }
  }
}

/// Folds its content upwards (clipped from the top) while `state` is collapsed.
struct CollapsibleHeader<Content: View>: View {
  let state: ScrollCollapse
  @ViewBuilder let content: () -> Content
  @State private var height: CGFloat = 0
  var body: some View {
    let folded = state.collapsed
    content().fixedSize(horizontal: false, vertical: true)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0 > 0 { height = $0 } }
      .frame(height: folded ? 0 : (height > 0 ? height : nil), alignment: .bottom)
      .opacity(folded ? 0 : 1)
      .clipped()
      .allowsHitTesting(!folded)
      .accessibilityHidden(folded)
  }
}

/// Inline title that appears once the header holding the real name has folded away.
struct CollapsedTitle: View {
  let state: ScrollCollapse
  let title: String
  var body: some View {
    Button { state.expand() } label: {
      Text(title).font(.headline).lineLimit(1)
    }
    .buttonStyle(.plain)
    .opacity(state.collapsed ? 1 : 0)
    .animation(.smooth(duration: 0.25), value: state.collapsed)
    .accessibilityHidden(!state.collapsed)
  }
}
