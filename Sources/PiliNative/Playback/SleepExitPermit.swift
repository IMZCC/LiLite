import Foundation

/// Serializes the final process-exit decision with account, transfer and disk commits.
final class SleepExitFence: @unchecked Sendable {
  static let shared = SleepExitFence()
  private let lock = NSLock()
  private var active = 0, token: UUID?, sealed = false
  private var lastEnd = ProcessInfo.processInfo.systemUptime
  enum Closed: LocalizedError {
    case closing
    var errorDescription: String? { "应用正在退出" }
  }
  func enter() throws -> () -> Void {
    try lock.withLock {
      guard !sealed else { throw Closed.closing }
      active += 1
    }
    return { self.lock.withLock { self.active -= 1; self.lastEnd = ProcessInfo.processInfo.systemUptime } }
  }
  func arm() -> UUID {
    lock.withLock {
      let id = UUID(); token = id; sealed = false; return id
    }
  }
  func cancel(_ id: UUID) {
    lock.withLock { if token == id { token = nil; sealed = false } }
  }
  func committed(_ id: UUID) -> Bool { lock.withLock { token == id && sealed } }
  func current(_ id: UUID) -> Bool { lock.withLock { token == id && !sealed } }
  /// Main-actor caller supplies the system action. The host fixture supplies a counter.
  @discardableResult
  func finish(_ id: UUID, quiet: TimeInterval = 0.8, perform: () -> Void) -> Bool {
    let ok = lock.withLock {
      guard token == id, !sealed, active == 0,
        ProcessInfo.processInfo.systemUptime - lastEnd >= quiet else { return false }
      sealed = true
      return true
    }
    if ok { perform() }
    return ok
  }
}

enum SleepTransferHold {
  /// taskKey includes the cache generation and track. No URL, cookie, or resume data is persisted.
  static func mayResume(_ saved: [String:Int], key: String, task: Int, suspended: Bool,
    transferring: Bool, downloadOwner: String?, currentOwner: String) -> Bool {
    suspended && transferring && saved[key] == task && downloadOwner == currentOwner
  }
}
