import Foundation

struct ResumePoint: Codable {
  let seconds: Double
  let modified: Date
}
@MainActor enum PlaybackMemory {
  static let key = "play.resume.points"
  private static var points: [String: ResumePoint] = {
    guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
    return (try? JSONDecoder().decode([String: ResumePoint].self, from: data)) ?? [:]
  }()
  static func id(_ cid: Int64, account: String?) -> String { "\(account ?? "guest"):\(cid)" }
  static func forgetStoredPoints() { points.removeAll(); UserDefaults.standard.removeObject(forKey:key) }
  static func read(_ key: String) -> Double { enabled ? points[key]?.seconds ?? 0 : 0 }
  static var enabled: Bool {
    UserDefaults.standard.object(forKey: "play.remember") as? Bool ?? true
  }
  static func store(_ id: String, seconds: Double, duration: Double) {
    guard enabled, seconds.isFinite, duration.isFinite, duration > 0, seconds >= 2 else { return }
    if seconds > duration - 4 {
      points[id] = nil
    } else {
      points[id] = .init(seconds: seconds, modified: .now)
    }
    if points.count > 600 {
      for p in points.sorted(by: { $0.value.modified < $1.value.modified }).prefix(60) {
        points[p.key] = nil
      }
    }
    if let data = try? JSONEncoder().encode(points) { UserDefaults.standard.set(data, forKey: key) }
  }
}
