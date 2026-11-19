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
/// Image settings read once near the root and handed down: every thumbnail used to subscribe
/// to user defaults itself, twice, as it scrolled in.
struct ImageDisplay: Equatable {
  var quality = 10
  var tint = NightAppearance.white
  /// Outside the root's environment (UIKit-hosted panels), read the stored values directly.
  static var stored: ImageDisplay {
    let d = UserDefaults.standard
    return ImageDisplay(
      quality: d.object(forKey: "images.quality") as? Int ?? 10,
      tint: d.object(forKey: "images.nightTint") as? Int ?? NightAppearance.white)
  }
}
private struct ImageDisplayKey: EnvironmentKey { static let defaultValue: ImageDisplay? = nil }
extension EnvironmentValues {
  var imageDisplay: ImageDisplay? {
    get { self[ImageDisplayKey.self] }
    set { self[ImageDisplayKey.self] = newValue }
  }
}
struct ImageDisplaySource: ViewModifier {
  @AppStorage("images.quality") private var quality = 10
  @AppStorage("images.nightTint") private var tint = NightAppearance.white
  func body(content: Content) -> some View {
    content.environment(\.imageDisplay, ImageDisplay(quality: quality, tint: tint))
  }
}
struct NightImage: ViewModifier {
  @Environment(\.colorScheme) private var scheme
  @Environment(\.imageDisplay) private var display
  var loaded: Bool
  func body(content: Content) -> some View {
    let tint = (display ?? .stored).tint
    // No filter at all unless dimming: an identity colour multiply still costs each image layer.
    if InterfacePresentation.dimImage(loaded: loaded, dark: scheme == .dark, tint: tint) {
      content.colorMultiply(NightAppearance.rgb(tint)).opacity(NightAppearance.components(tint).a)
    } else {
      content
    }
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
