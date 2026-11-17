import Foundation

enum AudioSequence: String, CaseIterable {
  case pause = "播完暂停"
  case list = "顺序播放"
  case one = "单曲循环"
  case all = "列表循环"
  case shuffle = "随机播放"
  enum Action: Equatable { case unchanged, stop, current, part(Int), row(Int), shuffled }
  func action(automatic: Bool, direction: Int, row: Int, count: Int, part: Int?, parts: Int)
    -> Action
  {
    guard (0..<count).contains(row), direction == -1 || direction == 1 else { return .unchanged }
    if automatic {
      if self == .pause { return .stop }
      if self == .one { return .current }
      if self != .shuffle, direction == 1, let part, part >= 0 && part + 1 < parts {
        return .part(part + 1)
      }
    }
    if self == .shuffle && count > 1 { return .shuffled }
    let next = row + direction
    if (0..<count).contains(next) { return .row(next) }
    guard automatic else { return .unchanged }
    if self == .all { return count == 1 ? .current : .row(0) }
    return .stop
  }
}
