import Foundation

struct ResumePoint: Codable {
  let seconds: Double
  let modified: Date
}
/// Where each video was left, saved every few seconds while it plays.
///
/// Kept in its own file, written on a background queue. It used to live in UserDefaults, and every
/// write there (every 8–12 s of playback) told every `@AppStorage` view in the app that defaults
/// had changed: the player page re-rendered as a whole, a 50–70 ms stall each time.
@MainActor enum PlaybackMemory {
  /// Where the points were kept before; read once to move them into the file.
  static let key = "play.resume.points"
  private static let disk = DispatchQueue(label: "PlaybackMemory.disk", qos: .utility)
  private nonisolated static let file: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("resume-points.json")
  }()
  private static var points: [String: ResumePoint] = load()

  private static func load() -> [String: ResumePoint] {
    if let data = try? Data(contentsOf: file),
      let saved = try? JSONDecoder().decode([String: ResumePoint].self, from: data)
    {
      return saved
    }
    let defaults = UserDefaults.standard
    guard let data = defaults.data(forKey: key),
      let saved = try? JSONDecoder().decode([String: ResumePoint].self, from: data)
    else { return [:] }
    save(saved)
    defaults.removeObject(forKey: key)
    return saved
  }
  private static func save(_ snapshot: [String: ResumePoint]) {
    disk.async {
      guard let data = try? JSONEncoder().encode(snapshot) else { return }
      try? FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? data.write(to: file, options: .atomic)
    }
  }
  static func id(_ cid: Int64, account: String?) -> String { "\(account ?? "guest"):\(cid)" }
  static func forgetStoredPoints() {
    points.removeAll()
    UserDefaults.standard.removeObject(forKey: key)
    disk.async { try? FileManager.default.removeItem(at: file) }
  }
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
    save(points)
  }
}
