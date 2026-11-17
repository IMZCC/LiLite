import Foundation

enum InterfacePresentation {
  static func colorChannels(_ raw: Int) -> (r: Double, g: Double, b: Double, a: Double) {
    let n = UInt32(truncatingIfNeeded: raw)
    return (
      Double((n >> 16) & 255) / 255, Double((n >> 8) & 255) / 255, Double(n & 255) / 255,
      Double((n >> 24) & 255) / 255
    )
  }
  static func dimImage(loaded: Bool, dark: Bool, tint: Int) -> Bool {
    loaded && dark && tint != Int(UInt32.max)
  }
  static func refreshChoices(maximum: Int) -> [Int] {
    let limit = min(1000, max(1, maximum))
    return Set([24, 30, 48, 60, 90, 120, limit].filter { $0 <= limit }).sorted()
  }
  static func columns(width: Double, gap: Double, desired: Double, accessible: Bool) -> Int {
    guard width.isFinite, width > 0, gap.isFinite, gap >= 0, desired.isFinite, !accessible else {
      return 1
    }
    let limit = min(500, max(150, desired))
    return Int(min(16, max(1, ceil(width / (limit + gap)))))
  }
}
