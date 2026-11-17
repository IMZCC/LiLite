import Foundation

@main enum ThemeColorsCheck {
  static func main() {
    // Primary-role fixtures from the pinned FlexSeedScheme 5.0.1 MCU suite.
    let cases: [(Int, Bool, Int, Int)] = [
      (1, false, 0xff0000ff, 0xff0001BB),
      (1, true, 0xff0000ff, 0xffbec2ff),
      (2, false, 0xff0000ff, 0xff000000),
      (2, true, 0xff0000ff, 0xffffffff),
      (3, false, 0xff0000ff, 0xff5d5d6c),
      (3, true, 0xff0000ff, 0xffc6c5d6),
      (4, false, 0xff0000ff, 0xff343dff),
      (4, true, 0xff0000ff, 0xffbec2ff),
      (5, false, 0xff0000ff, 0xff146c48),
      (5, true, 0xff0000ff, 0xff87d7ab),
      (6, false, 0xff0000ff, 0xff0001BB),
      (6, true, 0xff0000ff, 0xffbec2ff),
      (7, false, 0xff0000ff, 0xff5056a9),
      (7, true, 0xff0000ff, 0xffbec2ff),
      (8, false, 0xff0000ff, 0xff006688),
      (8, true, 0xff0000ff, 0xff76d1ff),
    ]
    for (style, night, color, expected) in cases {
      let actual = ThemeSeeds.palette(color, style: style, dark: night).primary
      precondition(actual == expected, "style \(style), dark=\(night): \(String(actual, radix:16)) vs \(String(expected, radix:16))")
    }
    for i in ThemeSeeds.colors.indices {
      for style in ThemeSeeds.styles.indices {
        let l = ThemeSeeds.palette(i, style: style, dark: false)
        let d = ThemeSeeds.palette(ThemeSeeds.seed(i), style: style, dark: true)
        precondition(l.primary != d.primary && (l.primary >> 24) == 255 && (d.surface >> 24) == 255)
      }
    }
    print("Themes: \(cases.count) pinned primary-role values and 19 seeds × 21 styles × light/dark passed")
  }
}
