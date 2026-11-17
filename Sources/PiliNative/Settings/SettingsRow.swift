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
        .background(color.gradient, in: RoundedRectangle(cornerRadius: 8.5, style: .continuous))
        .accessibilityHidden(true)
      configuration.title.foregroundStyle(.primary)
    }.padding(.vertical, 3)
  }
}
