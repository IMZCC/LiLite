import Foundation

enum SleepDeadline: Equatable {
  case off
  case scheduled(Date, afterItem: Bool)
  case finishingItem

  mutating func expire(now: Date, playing: Bool, live: Bool) -> Bool {
    guard case .scheduled(let end, let afterItem) = self, now >= end else { return false }
    if afterItem && playing && !live {
      self = .finishingItem
      return false
    }
    self = .off
    return true
  }
  mutating func finish() -> Bool {
    guard self == .finishingItem else { return false }
    self = .off
    return true
  }
}
