import SwiftUI

/// `NavigationLink` does nothing inside a context menu or `Menu`. A view that offers page links
/// from its menus applies `contextPushHost()`; the menu items are `ContextLink`s, which push
/// through the host's destination instead.
private struct ContextPushKey: EnvironmentKey {
  static let defaultValue: (@MainActor (AnyView) -> Void)? = nil
}
extension EnvironmentValues {
  var contextPush: (@MainActor (AnyView) -> Void)? {
    get { self[ContextPushKey.self] }
    set { self[ContextPushKey.self] = newValue }
  }
}
private struct ContextPushHost: ViewModifier {
  @State private var target: AnyView?
  @State private var shown = false
  func body(content: Content) -> some View {
    content
      .environment(\.contextPush, { view in
        target = view
        shown = true
      })
      .navigationDestination(isPresented: $shown) { target }
  }
}
extension View {
  func contextPushHost() -> some View { modifier(ContextPushHost()) }
}
struct ContextLink<Destination: View>: View {
  let title: String
  var systemImage: String? = nil
  let destination: () -> Destination
  @Environment(\.contextPush) private var push
  init(_ title: String, systemImage: String? = nil, @ViewBuilder destination: @escaping () -> Destination) {
    self.title = title
    self.systemImage = systemImage
    self.destination = destination
  }
  var body: some View {
    Button {
      push?(AnyView(destination()))
    } label: {
      if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
    }
    .disabled(push == nil)
  }
}
