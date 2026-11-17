import Foundation
import MaterialColorUtilities

struct ThemeSwatches: Equatable {
  let primary: Int, container: Int, secondary: Int, tertiary: Int, surface: Int
}
enum ThemeSeeds {
  static let colors: [(name: String, value: Int)] = [
    ("默认绿", 0xff5cb67b), ("粉红色", 0xffff7299), ("红色", 0xfff44336), ("橙色", 0xffff9800),
    ("琥珀色", 0xffffc107), ("黄色", 0xffffeb3b), ("酸橙色", 0xffcddc39), ("浅绿色", 0xff8bc34a),
    ("绿色", 0xff4caf50), ("青色", 0xff009688), ("蓝绿色", 0xff00bcd4), ("浅蓝色", 0xff03a9f4),
    ("蓝色", 0xff2196f3), ("靛蓝色", 0xff3f51b5), ("紫色", 0xff9c27b0), ("深紫色", 0xff673ab7),
    ("蓝灰色", 0xff607d8b), ("棕色", 0xff795548), ("灰色", 0xff9e9e9e),
  ]
  static let styles = ["柔和色调", "忠实原色", "单色", "中性", "鲜明", "表现力", "内容", "彩虹", "果彩",
    "标准", "经典", "柔和", "鲜艳", "鲜艳表面", "高对比", "极高对比", "明快", "鲜艳背景", "同色系", "糖果", "色度"]
  static let seedKey = "appearance.seed", styleKey = "appearance.palette", systemKey = "appearance.systemTint"
  static func valid(_ n: Int) -> Bool { colors.indices.contains(n) || (0x01000000...0xffffffff).contains(n) }
  static func seed(_ n: Int) -> Int { colors.indices.contains(n) ? colors[n].value : (valid(n) ? n | 0xff000000 : colors[0].value) }
  static func previous(_ name: String?) -> Int {
    switch name { case "rose": return 0xffc9295e; case "blue": return 12; case "orange": return 3; case "purple": return 14; default: return 0 }
  }
  static func palette(_ n: Int, style: Int, dark: Bool) -> ThemeSwatches {
    let color = Hct.fromInt(seed(n))
    let scheme: DynamicScheme
    switch style {
    case 0: scheme = SchemeTonalSpot(sourceColorHct: color, isDark: dark, contrastLevel: 0)
    case 1: scheme = SchemeFidelity(sourceColorHct: color, isDark: dark, contrastLevel: 0)
    case 2: scheme = SchemeMonochrome(sourceColorHct: color, isDark: dark, contrastLevel: 0)
    case 3: scheme = SchemeNeutral(sourceColorHct: color, isDark: dark, contrastLevel: 0)
    case 4: scheme = SchemeVibrant(sourceColorHct: color, isDark: dark, contrastLevel: 0)
    case 5: scheme = SchemeExpressive(sourceColorHct: color, isDark: dark, contrastLevel: 0)
    case 6: scheme = SchemeContent(sourceColorHct: color, isDark: dark, contrastLevel: 0)
    case 7: scheme = SchemeRainbow(sourceColorHct: color, isDark: dark, contrastLevel: 0)
    case 8: scheme = SchemeFruitSalad(sourceColorHct: color, isDark: dark, contrastLevel: 0)
    default:
      let index = styles.indices.contains(style) ? style : 10
      let r = ThemeToneRecipes.values[index - 9][dark ? 1 : 0]
      let p = TonalPalette.of(color.hue, max(r[1]!, r[0] ?? color.chroma))
      let s = TonalPalette.of(color.hue, max(r[3]!, r[2] ?? color.chroma))
      let t = TonalPalette.of((color.hue + r[6]!).truncatingRemainder(dividingBy: 360), max(r[5]!, r[4] ?? color.chroma))
      return .init(primary: p.tone(r[7]!), container: p.tone(r[8]!), secondary: s.tone(r[9]!),
        tertiary: t.tone(r[10]!), surface: TonalPalette.of(color.hue, r[11] ?? color.chroma).tone(r[12]!))
    }
    return .init(primary: scheme.primary, container: scheme.primaryContainer,
      secondary: scheme.secondary, tertiary: scheme.tertiary, surface: scheme.surface)
  }
}
