import Foundation

enum SubtitlePreference: Int, CaseIterable {
  case off, on, withoutAI, auto
  static let key = "caption.preference"
  static var current: Self { Self(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .off }
  var title: String {
    switch self {
    case .off: "默认关闭"
    case .on: "优先人工字幕"
    case .withoutAI: "跳过 AI 字幕"
    case .auto: "静音时允许 AI 字幕"
    }
  }
  func select<T>(_ rows: [T], language: (T) -> String, isAI: (T) -> Bool, volume: Float) -> T? {
    guard self != .off, let first = rows.first else { return nil }
    let machine = isAI(first) || language(first).lowercased().hasPrefix("ai")
    return !machine || self == .on || (self == .auto && volume <= 0) ? first : nil
  }
}
