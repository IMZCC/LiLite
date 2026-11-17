import Foundation

/// Complete all fallible staging before the final Keychain update. Each earlier external
/// mutation publishes an undo receipt only after its atomic write succeeds.
struct DataPackRestoreJournal {
  private var undo: [() async throws -> Void] = []
  mutating func wrote(_ body: @escaping () async throws -> Void) { undo.append(body) }
  func rollback(_ cause: Error) async -> Error {
    var errors: [String] = []
    for work in undo.reversed() {
      do { try await work() } catch { errors.append(error.localizedDescription) }
    }
    return errors.isEmpty
      ? cause : ServiceError(cause.localizedDescription + "\n未能撤销：" + errors.joined(separator: "、"))
  }
}

struct StagedPreferences {
  var values: [String: Any] = [:]
  var removals: Set<String> = []
  func commit(_ target: UserDefaults) {
    for k in removals where values[k] == nil { target.removeObject(forKey: k) }
    for (k, v) in values { target.set(v, forKey: k) }
  }
  static func collect(removing keys: Set<String>, _ prepare: (UserDefaults) throws -> Void) throws
    -> Self
  {
    let name = "PiliNative.staged-backup." + UUID().uuidString
    guard let suite = UserDefaults(suiteName: name) else { throw ServiceError("无法准备设置") }
    defer { suite.removePersistentDomain(forName: name) }
    try prepare(suite)
    return Self(values: suite.persistentDomain(forName: name) ?? [:], removals: keys)
  }
}
