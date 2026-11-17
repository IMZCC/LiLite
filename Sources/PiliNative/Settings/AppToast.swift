import SwiftUI

/// App-wide transient message: anything can post `.piliToast` with a `String` object and a glass
/// capsule slides down from the top for a moment.
private struct AppToastHost: ViewModifier {
  @State private var message: String?
  @State private var token = UUID()
  func body(content: Content) -> some View {
    content
      .overlay(alignment: .top) {
        if let message {
          Label(message, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.medium))
            .symbolRenderingMode(.multicolor)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .piliGlass(in: Capsule())
            .padding(.top, 6).padding(.horizontal, 24)
            .transition(.move(edge: .top).combined(with: .opacity))
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isStaticText)
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .piliToast).receive(on: RunLoop.main)) {
        note in
        guard let text = note.object as? String, !text.isEmpty else { return }
        let t = UUID()
        token = t
        withAnimation(.snappy(duration: 0.35)) { message = text }
        UIAccessibility.post(notification: .announcement, argument: text)
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(2.4))
          if token == t { withAnimation(.easeOut(duration: 0.3)) { message = nil } }
        }
      }
  }
}
extension View {
  func piliToastHost() -> some View { modifier(AppToastHost()) }
}
enum AppToast {
  @MainActor static func show(_ text: String) {
    NotificationCenter.default.post(name: .piliToast, object: text)
  }
}
