import SwiftUI
import UIKit

enum NightAppearance {
  static let white = Int(UInt32.max), defaultTint = 0xff99_9999
  static func components(_ raw: Int) -> (r: Double, g: Double, b: Double, a: Double) {
    InterfacePresentation.colorChannels(raw)
  }
  static func rgb(_ raw: Int) -> Color {
    let v = components(raw)
    return Color(.sRGB, red: v.r, green: v.g, blue: v.b, opacity: 1)
  }
  @MainActor static func pack(_ color: Color) -> Int? {
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
    func byte(_ v: CGFloat) -> UInt32 { UInt32((min(1, max(0, v)) * 255).rounded()) }
    let packed = (byte(a) << 24) | (byte(r) << 16) | (byte(g) << 8) | byte(b)
    return Int(packed)
  }
}
struct NightImage: ViewModifier {
  @Environment(\.colorScheme) private var scheme
  @AppStorage("images.nightTint") private var tint = NightAppearance.white
  var loaded: Bool
  func body(content: Content) -> some View {
    let active = InterfacePresentation.dimImage(loaded:loaded,dark:scheme == .dark,tint:tint)
    content.colorMultiply(active ? NightAppearance.rgb(tint) : .white).opacity(
      active ? NightAppearance.components(tint).a : 1)
  }
}
struct NightCanvas: ViewModifier {
  @Environment(\.colorScheme) private var scheme
  @AppStorage("appearance.pureBlack") private var pure = false
  func body(content: Content) -> some View {
    let active = pure && scheme == .dark
    content.scrollContentBackground(active ? .hidden : .automatic)
      .background { if active { Color.black.ignoresSafeArea() } }
      .modifier(NativeNavigationBackground(black: active))
  }
}
struct NightSettings: View {
  @AppStorage("appearance.pureBlack") private var pure = false
  @AppStorage("images.nightTint") private var tint = NightAppearance.white
  @AppStorage("ui.toastOpacity") private var opacity = 1.0
  var body: some View {
    Toggle("深色模式使用纯黑背景", isOn: $pure).settingAnchor("SettingsView/深色模式使用纯黑背景")
    Toggle(
      "深色模式调暗网络图片",
      isOn: Binding(
        get: { tint != NightAppearance.white },
        set: { tint = $0 ? NightAppearance.defaultTint : NightAppearance.white })).settingAnchor("SettingsView/深色模式调暗网络图片")
    if tint != NightAppearance.white {
      ColorPicker(
        "图片叠加色",
        selection: Binding(
          get: { NightAppearance.rgb(tint).opacity(NightAppearance.components(tint).a) },
          set: { if let v = NightAppearance.pack($0) { tint = v } }), supportsOpacity: true).settingAnchor("SettingsView/图片叠加色")
    }
    SettingSlider(title: "提示不透明度", value: $opacity, range: 0...1, step: 0.1).settingAnchor("SettingsView/提示不透明度")
  }
}
struct ToastAlpha: ViewModifier {
  @AppStorage("ui.toastOpacity") private var opacity = 1.0
  func body(content: Content) -> some View { content.opacity(min(1, max(0, opacity))) }
}
