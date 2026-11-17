import Foundation

enum ViewportProgress: Int, CaseIterable {
  case always, never, fullOnly, inlineOnly
  var name: String {
    switch self {
    case .always: return "始终显示"
    case .never: return "始终隐藏"
    case .fullOnly: return "仅全屏显示"
    case .inlineOnly: return "仅内嵌显示"
    }
  }
  func visible(fullscreen: Bool, controls: Bool, seeking: Bool) -> Bool {
    !controls
      && (seeking || self == .always || (self == .fullOnly && fullscreen)
        || (self == .inlineOnly && !fullscreen))
  }
}

struct ViewportZoom: Equatable {
  var scale = 1.0, x = 0.0, y = 0.0
  func magnified(_ factor: Double, anchor: CGPoint, size: CGSize, shrinks: Bool) -> Self {
    guard factor.isFinite, factor > 0, size.width > 0, size.height > 0 else { return self }
    let next = max(shrinks ? 0.75 : 1, min(2, scale * factor))
    let ratio = next / scale
    func offset(_ original: Double, _ anchor: Double, _ length: Double) -> Double {
      let maxShift = max(0, length * (next - 1) / 2)
      let shifted = original * ratio + length * (anchor - 0.5) * (1 - ratio)
      return min(maxShift, max(-maxShift, shifted))
    }
    return .init(
      scale: next, x: offset(x, anchor.x, size.width), y: offset(y, anchor.y, size.height))
  }
}
