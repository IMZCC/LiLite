import Foundation

enum OfflineExtras {
  struct Language: Codable, Identifiable {
    let id: String, name: String, cues: [SubtitleCue]
    var language: String? = nil
    var ai: Bool? = nil
  }
  struct Index: Codable { let version: String, segments: Int }
  private static func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
    try JSONDecoder().decode(type, from: Data(contentsOf: url, options: .mappedIfSafe))
  }
  private static func save<T: Encodable>(_ value: T, _ url: URL) throws {
    try Task.checkCancellation()
    try JSONEncoder().encode(value).write(to: url, options: .atomic)
  }
  static func updateComments(_ video: OfflineVideo, dir: URL) async throws {
    let version = UUID().uuidString
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let next = dir.appendingPathComponent(version, isDirectory: true)
    try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
    var published = false
    defer { if !published { try? FileManager.default.removeItem(at: next) } }
    let duration: Int
    if let stored = video.seconds, stored > 0 {
      duration = stored
    } else {
      guard let uid = video.cacheOwner else { throw ServiceError("缺少缓存账号") }
      if let ep = video.episode {
        let d = try await BiliAPI.shared.cacheEpisode(
          ep, cid: video.cid, bvid: video.bvid, owner: uid)
        guard let t = d.seconds, t > 0 else { throw ServiceError("未获取到分集时长") }; duration = t
      } else {
        let detail = try await BiliAPI.shared.offlineArchiveDetails(video.bvid, owner: uid)
        try detail.authorize(video.bvid, cid: video.cid)
        guard
          let d = detail.pages?.first(where: { $0.cid == video.cid })?.duration
            ?? ((detail.pages?.count ?? 0) <= 1 ? detail.duration : nil), d > 0
        else { throw ServiceError("未获取到分集时长") }
        duration = d
      }
    }
    guard duration > 0, duration <= 30 * 24 * 3600 else { throw ServiceError("分集时长异常") }
    let count = 1 + (duration - 1) / 360
    let uid = try await AccountJar.shared.current(.role(.main))?.id ?? ""
    for first in stride(from: 1, through: count, by: 4) {
      try await authorize(video)
      try await withThrowingTaskGroup(of: Void.self) { group in
        for n in first...min(count, first + 3) {
          group.addTask {
            let rows = try await BiliAPI.shared.commentSegment(
              cid: video.cid, aid: video.aid, index: n, expectedAccount: uid)
            try save(rows, next.appendingPathComponent("\(n).json"))
          }
        }
        try await group.waitForAll()
      }
    }
    try await authorize(video)
    guard (try await AccountJar.shared.current(.role(.main))?.id ?? "") == uid else {
      throw ServiceError("读取弹幕的账号已切换")
    }
    let indexURL = dir.appendingPathComponent("comments.json")
    let old = try? read(Index.self, indexURL)
    try save(Index(version: version, segments: count), indexURL)
    published = true
    if let old, UUID(uuidString: old.version) != nil && old.version != version {
      try? FileManager.default.removeItem(at: dir.appendingPathComponent(old.version))
    }
  }
  static func updateCaptions(_ video: OfflineVideo, dir: URL) async throws {
    try await authorize(video)
    let uid = try await AccountJar.shared.current(.role(.main))?.id ?? ""
    let tracks = try await BiliAPI.shared.subtitles(
      video.bvid, cid: video.cid, aid: video.aid, expectedAccount: uid)
    var languages: [Language] = []
    var seen = Set<String>()
    for t in tracks where seen.insert(t.id).inserted {
      try Task.checkCancellation()
      languages.append(
        .init(
          id: t.id, name: t.lan_doc, cues: try await BiliAPI.shared.cues(t), language: t.lan,
          ai: t.isAI))
    }
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try await authorize(video)
    guard (try await AccountJar.shared.current(.role(.main))?.id ?? "") == uid else {
      throw ServiceError("读取字幕的账号已切换")
    }
    try save(languages, dir.appendingPathComponent("captions.json"))
  }
  static func captions(_ dir: URL) async -> [Language] {
    (try? read([Language].self, dir.appendingPathComponent("captions.json"))) ?? []
  }
  static func comments(_ dir: URL, segment: Int) async -> [Bullet] {
    guard let idx = try? read(Index.self, dir.appendingPathComponent("comments.json")), segment > 0,
      segment <= idx.segments, UUID(uuidString: idx.version) != nil
    else { return [] }
    let version = dir.appendingPathComponent(idx.version)
    return (max(1, segment - 1)...segment).flatMap {
      (try? read([Bullet].self, version.appendingPathComponent("\($0).json"))) ?? []
    }
  }
}
