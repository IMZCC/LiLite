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
  /// On (the default): a horizontal swipe moves by `seekSpan`, as the official client. Off: the
  /// fixed "横滑整屏" seconds or percentage.
  static let seekCurveKey = "player.seekCurve"
  /// How far a finger travels from where it went down before its slide's direction is decided,
  /// as in the official client (`singlePan:`, 10 pt), which is also how far a long press allows.
  static let decisionDistance: Double = 10
  static func axis(dx: Double, dy: Double, x: Double, width: Double, levels: Bool, screen: Bool) -> Axis? {
    guard width > 0 else { return nil }
    if abs(dx) > 3 * abs(dy) { return .seek }
    guard abs(dy) > 3 * abs(dx) else { return nil }
    if x < width / 3 { return levels ? .brightness : nil }
    if x >= width * 2 / 3 { return levels ? .volume : nil }
    return screen ? .fullscreen : nil
  }
  /// As the official client: a horizontal seek is cancelled while the finger is in the top 30 %
  /// of the picture and within 10 % of either side ("松开手指，取消进退").
  static func cancelsSeek(_ p: CGPoint, size: CGSize) -> Bool {
    guard size.width > 0, size.height > 0 else { return false }
    return p.y < size.height * 0.3 && (p.x > size.width * 0.9 || p.x < size.width * 0.1)
  }
  /// Seconds a swipe across the whole picture moves, by the video's length (the official
  /// client's curve): the whole video up to a minute, then rising to 100 s at 23 minutes, 120 s
  /// at 45 minutes and towards about 400 s for very long videos.
  static func seekSpan(duration: Double) -> Double {
    guard duration.isFinite, duration > 0 else { return 0 }
    let s = duration
    let span: Double
    if s < 60 { span = s }
    else if s < 1380 { span = 100 - pow((s - 1380) / 209, 2) }
    else if s < 2700 { span = 100 + pow((s - 1380) / 295, 2) }
    else { span = atan((s - 2700) / 1000) * 177 + 120 }
    return min(s, max(1, span.rounded(.down)))
  }
  /// Brightness / volume while sliding, as the official client's tracker: the level moves by the
  /// finger's travel over the picture's height times a factor (brightness 0.5, volume 1.5), and
  /// turning back starts from the level reached, so there is no dead travel after hitting 0 or 1.
  struct LevelTracker {
    let factor: Double
    private var base: Double, anchor = 0.0, last = 0.0, rising: Bool?
    init(start: Double, brightness: Bool) {
      factor = brightness ? 0.5 : 1.5
      base = min(1, max(0, start))
    }
    /// `progress` is the upward travel so far as a fraction of the picture's height.
    mutating func level(_ progress: Double) -> Double {
      let up = progress > last ? true : progress < last ? false : rising
      if let up, up != rising {
        let reached = min(1, max(0, base + (last - anchor) * factor))
        anchor = last
        base = reached
        rising = up
      }
      last = progress
      return min(1, max(0, base + (progress - anchor) * factor))
    }
  }
}
