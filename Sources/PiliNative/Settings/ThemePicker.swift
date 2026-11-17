import SwiftUI
import UIKit

/// Apple system accent colors. Stored values stay compatible with the original seed indices
/// (0...18) and packed ARGB custom colors, so backups and older installs keep working.
enum AccentPalette {
  struct Preset: Identifiable {
    let name: String, color: UIColor, storedIndex: Int
    var id: Int { storedIndex }
  }
  static let presets: [Preset] = [
    .init(name: "蓝色", color: .systemBlue, storedIndex: 0),
    .init(name: "靛蓝", color: .systemIndigo, storedIndex: 13),
    .init(name: "紫色", color: .systemPurple, storedIndex: 14),
    .init(name: "粉色", color: .systemPink, storedIndex: 1),
    .init(name: "红色", color: .systemRed, storedIndex: 2),
    .init(name: "橙色", color: .systemOrange, storedIndex: 3),
    .init(name: "黄色", color: .systemYellow, storedIndex: 5),
    .init(name: "绿色", color: .systemGreen, storedIndex: 8),
    .init(name: "蓝绿", color: .systemTeal, storedIndex: 9),
    .init(name: "青色", color: .systemCyan, storedIndex: 10),
    .init(name: "棕色", color: .systemBrown, storedIndex: 17),
    .init(name: "石墨", color: .systemGray, storedIndex: 18),
  ]
  /// Maps every original seed index onto the closest Apple system color.
  private static let legacy: [Int: Int] = [
    0: 0, 1: 1, 2: 2, 3: 3, 4: 5, 5: 5, 6: 8, 7: 8, 8: 8, 9: 9, 10: 10, 11: 10, 12: 0,
    13: 13, 14: 14, 15: 14, 16: 18, 17: 17, 18: 18,
  ]
  /// The preset a stored value resolves to, or nil for a custom color.
  static func preset(for stored: Int) -> Preset? {
    guard let index = legacy[stored] else { return nil }
    return presets.first { $0.storedIndex == index }
  }
  static func color(for stored: Int) -> Color {
    if let preset = preset(for: stored) { return Color(uiColor: preset.color) }
    if ThemeSeeds.valid(stored) { return NightAppearance.rgb(stored | 0xff00_0000) }
    return Color(uiColor: .systemBlue)
  }
  static func resolved(_ stored: Int) -> Int {
    stored >= 0 ? stored : ThemeSeeds.previous(UserDefaults.standard.string(forKey: "accent"))
  }
}

struct NativeTheme: ViewModifier {
  @AppStorage(ThemeSeeds.seedKey) private var seed = -1
  @AppStorage(ThemeSeeds.systemKey) private var system = false
  func body(content: Content) -> some View {
    let tint: Color? = system ? nil : AccentPalette.color(for: AccentPalette.resolved(seed))
    return content.tint(tint).accentColor(tint)
  }
}

struct ThemePicker: View {
  @AppStorage(ThemeSeeds.seedKey) private var stored = -1
  @AppStorage(ThemeSeeds.systemKey) private var system = false
  private var selected: Int { AccentPalette.resolved(stored) }
  private let columns = [GridItem(.adaptive(minimum: 52), spacing: 14)]
  var body: some View {
    Form {
      Section {
        Toggle("跟随系统强调色", isOn: $system).settingAnchor("ThemePicker/跟随系统强调色")
      } footer: {
        Text("开启后使用系统默认的蓝色强调色")
      }
      if !system {
        Section("强调色") {
          LazyVGrid(columns: columns, spacing: 16) {
            ForEach(AccentPalette.presets) { preset in
              swatch(preset)
            }
          }.padding(.vertical, 8)
        }.settingAnchor("ThemePicker/预设颜色")
        Section {
          ColorPicker(
            "自定义颜色",
            selection: Binding(
              get: { AccentPalette.color(for: selected) },
              set: { if let packed = NightAppearance.pack($0) { stored = packed } }),
            supportsOpacity: false
          ).settingAnchor("ThemePicker/自定义颜色")
        }
      }
    }.navigationTitle("主题颜色")
  }
  private func swatch(_ preset: AccentPalette.Preset) -> some View {
    let current = AccentPalette.preset(for: selected)?.storedIndex == preset.storedIndex
    return Button {
      TouchFeedback.light()
      stored = preset.storedIndex
    } label: {
      VStack(spacing: 6) {
        Circle().fill(Color(uiColor: preset.color)).frame(width: 40, height: 40)
          .overlay {
            if current {
              Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
            }
          }
          .padding(3)
          .overlay { if current { Circle().strokeBorder(Color(uiColor: preset.color), lineWidth: 2) } }
        Text(preset.name).font(.caption).foregroundStyle(current ? .primary : .secondary)
      }.frame(maxWidth: .infinity)
    }.buttonStyle(.plain)
      .accessibilityLabel(preset.name).accessibilityAddTraits(current ? .isSelected : [])
  }
}
