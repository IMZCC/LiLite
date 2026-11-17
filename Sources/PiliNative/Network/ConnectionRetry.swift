import Foundation

struct ConnectionRetry: Sendable {
  let count: Int, delayMillis: Int
  init(count: Int, delayMillis: Int) {
    self.count = min(8, max(0, count))
    self.delayMillis = min(1000, max(0, delayMillis))
  }
  static func current(_ defaults: UserDefaults = .standard) -> Self {
    .init(
      count: (defaults.object(forKey: "network.retryCount") as? NSNumber)?.intValue ?? 2,
      delayMillis: (defaults.object(forKey: "network.retryDelay") as? NSNumber)?.intValue ?? 500)
  }
  func perform<T>(
    readOnly: Bool,
    wait: (Int) async throws -> Void = { ms in
      try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }, attempt: (Int) async throws -> T
  ) async throws -> T {
    var index = 0
    while true {
      try Task.checkCancellation()
      do { return try await attempt(index) } catch {
        try Task.checkCancellation()
        guard readOnly, index < count, let code = (error as? URLError)?.code else { throw error }
        switch code {
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .timedOut,
          .notConnectedToInternet, .networkConnectionLost:
          break
        default: throw error
        }
        index += 1
        if delayMillis > 0 { try await wait(index * delayMillis) }
      }
    }
  }
}
