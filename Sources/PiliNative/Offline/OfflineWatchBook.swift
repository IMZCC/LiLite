import Foundation

@MainActor enum OfflineWatchBook {
  struct Point: Codable, Equatable {
    let seconds: Double, duration: Double
    var completed: Bool { seconds >= max(0, duration - 0.4) }
    var start: Double { completed ? 0 : seconds }
  }
  static let changed = Notification.Name("PiliOfflineWatchChanged")
  private static func key(_ token: String) -> String { "offline.watch.1." + token }
  static func read(_ token: String, viewer: String?, defaults: UserDefaults = .standard) -> Point? {
    guard defaults.object(forKey: "play.remember") as? Bool != false else { return nil }
    return data(token, defaults)[viewer ?? "guest"]
  }
  private static func data(_ token: String, _ d: UserDefaults) -> [String: Point] {
    d.data(forKey: key(token)).flatMap { try? JSONDecoder().decode([String: Point].self, from: $0) }
      ?? [:]
  }
  static func store(
    _ token: String, viewer: String?, seconds: Double, duration: Double, completed: Bool = false,
    defaults: UserDefaults = .standard
  ) {
    guard defaults.object(forKey: "play.remember") as? Bool != false, duration.isFinite,
      duration > 0, seconds.isFinite, seconds >= 0, seconds > 0 || completed
    else { return }
    var rows = data(token, defaults)
    let who = viewer ?? "guest"
    let point = Point(seconds: completed ? duration : min(seconds, duration), duration: duration)
    guard rows[who] != point else { return }
    rows[who] = point
    if let bytes = try? JSONEncoder().encode(rows) {
      defaults.set(bytes, forKey: key(token))
      NotificationCenter.default.post(name: changed, object: token)
    }
  }
  static func remove(_ token: String, defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: key(token))
    NotificationCenter.default.post(name: changed, object: token)
  }
}
