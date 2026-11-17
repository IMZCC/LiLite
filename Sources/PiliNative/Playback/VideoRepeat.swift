import Foundation

enum VideoRepeat: Int, CaseIterable, Identifiable {
  case pause, order, one, cycle, related
  static let key = "play.repeat"
  var id: Self { self }
  var label: String {
    switch self {
    case .pause: "播完暂停"
    case .order: "顺序播放"
    case .one: "单个循环"
    case .cycle: "列表循环"
    case .related: "自动连播"
    }
  }
  static func current(_ defaults: UserDefaults = .standard) -> Self {
    Self(rawValue: defaults.integer(forKey: key)) ?? .pause
  }
  func after<T: Equatable>(_ id: T, in ids: [T], wrap: Bool = true) -> T? {
    guard self != .one, self != .pause, let i = ids.firstIndex(of: id) else { return nil }
    if i + 1 < ids.count { return ids[i + 1] }
    return self == .cycle && wrap ? ids.first : nil
  }
}
func manualNeighbor<T: Equatable>(_ id: T, in items: [T], forward: Bool, wrap: Bool) -> T? {
  guard items.count > 1, let i = items.firstIndex(of: id) else { return nil }
  let next = i + (forward ? 1 : -1)
  if items.indices.contains(next) { return items[next] }
  return wrap ? (forward ? items.first : items.last) : nil
}
typealias CloudStep = @MainActor (Bool, Bool) async -> Bool
enum NextPlayback: Equatable { case advanced, restart, end, failed }
typealias CloudAdvance = @MainActor (Bool, VideoRepeat) async -> NextPlayback
