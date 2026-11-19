import SwiftUI

struct SettingsRowLabel: View {
  let title: String, symbol: String
  var color: Color = .gray
  var body: some View {
    Label(title, systemImage: symbol).labelStyle(SettingsIconLabelStyle(color: color))
  }
}

struct SettingsIconLabelStyle: LabelStyle {
  var color: Color = .gray
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 14) {
      configuration.icon.font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.white).frame(width: 30, height: 30)
        .iconGradient(color, cornerRadius: 8.5)
        .accessibilityHidden(true)
      configuration.title.foregroundStyle(.primary)
    }.padding(.vertical, 3)
  }
}

extension View {
  /// `color.gradient` behind an icon, made of layers Core Animation draws itself: a gradient
  /// filling a shape went through SwiftUI's GPU renderer instead, which cost more per icon and
  /// whose first use (the 我的 page) stalled ~120 ms setting the GPU up on the main thread.
  /// `cornerRadius` nil gives a circle.
  func iconGradient(_ color: Color, cornerRadius: CGFloat? = nil) -> some View {
    background {
      ZStack {
        color
        LinearGradient(colors: [.white.opacity(0.2), .clear, .black.opacity(0.06)], startPoint: .top, endPoint: .bottom)
      }
      .modifier(IconGradientClip(cornerRadius: cornerRadius))
    }
  }
}
private struct IconGradientClip: ViewModifier {
  let cornerRadius: CGFloat?
  func body(content: Content) -> some View {
    if let cornerRadius {
      content.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    } else {
      content.clipShape(Circle())
    }
  }
}
