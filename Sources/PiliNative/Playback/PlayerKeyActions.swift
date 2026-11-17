import Foundation
import Combine

// Key action requests are values passed only to the presenting player. Notifications are reserved
// for read-only repaint after a confirmed mutation; they never initiate a social write.
struct PlayerKeyTicket: Equatable {
  // Separate declarations: a shared `let` mixing an initialized and uninitialized binding is
  // rejected by non-whole-module compilation.
  let id = UUID()
  let effect: PlayerKeyEffect, scope: String, owner: String
}
@MainActor final class PlayerKeyMemory:ObservableObject {
  static let shared = PlayerKeyMemory()
  private struct Key: Hashable { let owner: String, aid: Int64 }
  @Published private var later = [Key: Bool]()
  func contains(_ aid: Int64, owner: String, origin: Bool) -> Bool {
    later[.init(owner: owner, aid: aid)] ?? origin
  }
  func mark(_ aid: Int64, owner: String, value: Bool) {
    if later.count >= 256 { later.removeAll() }
    later[.init(owner: owner, aid: aid)] = value
  }
  static let changed = Notification.Name("PiliNative.engagement.accepted")
}
