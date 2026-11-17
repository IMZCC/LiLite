import Foundation

enum FullscreenMode: Int, CaseIterable {
  case video = 0
  case keep, portrait, landscape, ratio
  var title: String {
    switch self {
    case .video: "跟随视频方向"
    case .keep: "保持当前方向"
    case .portrait: "竖屏"
    case .landscape: "横屏"
    case .ratio: "按屏幕和视频比例"
    }
  }
  enum Orientation { case portrait, landscape }
  func wanted(videoWidth: Double, videoHeight: Double, screenWidth: Double, screenHeight: Double)
    -> Orientation?
  {
    switch self {
    case .keep: return nil
    case .portrait: return .portrait
    case .landscape: return .landscape
    case .ratio:
      let small = min(screenWidth, screenHeight)
      let large = max(screenWidth, screenHeight)
      if small > 0 && large / small < 1.2 { return .portrait }
      fallthrough
    case .video:
      guard videoWidth > 0, videoHeight > 0 else { return nil }
      return videoWidth >= videoHeight ? .landscape : .portrait
    }
  }
  static func swipe(
    fullscreen: Bool, reverse: Bool, x: Double, width: Double, dx: Double, dy: Double
  ) -> Bool {
    guard width > 0, x >= width / 3, x <= width * 2 / 3, abs(dy) > 2.5, abs(dy) > abs(dx) * 3 else {
      return false
    }
    return ((dy < 0) != reverse) != fullscreen
  }
}

enum PlayerSlide {
  enum Axis { case seek, brightness, volume, fullscreen }
  static func axis(dx: Double, dy: Double, x: Double, width: Double, levels: Bool, screen: Bool) -> Axis? {
    guard width > 0 else { return nil }
    if abs(dx) > 3 * abs(dy) { return .seek }
    guard abs(dy) > 3 * abs(dx) else { return nil }
    if x < width / 3 { return levels ? .brightness : nil }
    if x >= width * 2 / 3 { return levels ? .volume : nil }
    return screen ? .fullscreen : nil
  }
  static func level(_ initial: Double, dy: Double, height: Double, brightness: Bool) -> Double {
    min(1, max(0, initial - dy / (max(1, height) * (brightness ? 3 : 0.5))))
  }
}
