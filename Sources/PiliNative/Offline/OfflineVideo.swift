import Foundation

struct EpisodeResource: Codable, Equatable {
  let id: Int64, course: Bool
  var title: String { course ? "课程" : "剧集" }
  var page: URL {
    URL(
      string: "https://www.bilibili.com/" + (course ? "cheese" : "bangumi") + "/play/ep"
        + String(id))!
  }
}

enum OfflinePlace: Codable, Hashable {
  case app
  case folder(UUID)
}

struct OfflineVideo: Codable, Identifiable {
  enum Phase: String, Codable { case queued, transferring, paused, saved, failed }
  let bvid: String, cid: Int64
  var title: String
  let part: String
  var audioMeasurements: AudioMeasurements? = nil
  var episode: EpisodeResource?, cacheOwner: String?, episodeClips: [EpisodeClip]?
  // Old packages keep their original file names; new ones separate different video identities.
  var scoped: Bool? = nil, cover: String? = nil, singleFile: Bool?, collectionTitle: String?
  var mediaID: String { "\(bvid)-\(cid)" }
  var id: String {
    guard scoped == true else { return mediaID }
    let who = (cacheOwner ?? "").isEmpty ? "g" : "u" + (cacheOwner ?? "")
    let resource = episode.map { ($0.course ? "~c" : "~p") + String($0.id) } ?? ""
    return mediaID + "~" + who + resource
  }
  var sealsMedia: Bool { episode != nil || (scoped == true && cacheOwner?.isEmpty == false) }
  func matchesOwner(_ uid: String) -> Bool { cacheOwner == uid }
  func visible(to uid: String) -> Bool {
    matchesOwner(uid) || (cacheOwner == nil && episode == nil)
  }
  var validScope: Bool {
    guard let owner = cacheOwner else { return scoped != true }
    return owner.isEmpty
      || (owner.utf8.count <= 20 && owner.utf8.allSatisfy { (48...57).contains($0) })
  }
  var token: String { id + ":" + (generation?.uuidString ?? "original") }
  var phase: Phase = .queued
  var error: String?
  var added: Date = .now
  var generation: UUID?
  var audioQuality: Int?
  var quality: Int?
  var aid: Int64?
  var seconds: Int?
  var pageOrder: Int?, seriesID: String?
  var groupKey: String { seriesID ?? bvid }
  var includeExtras: Bool?
  var attachmentStamp: UUID?, mediaBytes: Int64?
  var uploader: String?
  var extrasIssue: String?
  var renewedComponents: [String]?, fullTracks: [String]?
  var mediaIdentity: [String: String]?
  var storedAt: OfflinePlace?, moveTo: OfflinePlace?, retire: OfflinePlace?
  var retirementHashes: [String: String]?
  var storageIssue: String?
  var location: OfflinePlace { storedAt ?? .app }
  var streams: [String]?
  var legacyDurations: [Double]?
  var components: [String] { streams ?? ["movie"] }
  var legacyMedia: Bool { LegacyMediaComponents.ordered(components) }
  func key(_ component: String) -> String {
    if let generation { return id + "|" + generation.uuidString + "|" + component }
    return id
  }
}

struct OfflineGroup: Identifiable {
  let id: String, title: String, parts: [OfflineVideo]
  static func groups(_ list: [OfflineVideo]) -> [Self] {
    var keys: [String] = []
    var rows: [String: [OfflineVideo]] = [:]
    for v in list {
      if rows[v.groupKey] == nil { keys.append(v.groupKey) }
      rows[v.groupKey, default: []].append(v)
    }
    return keys.compactMap { k in
      guard let r = rows[k], let first = r.first else { return nil }
      let sorted = r.sorted { a, b in
        if let x = a.pageOrder, let y = b.pageOrder, x != y { return x < y }
        if (a.pageOrder != nil) != (b.pageOrder != nil) { return a.pageOrder != nil }
        if a.added != b.added { return a.added < b.added }
        return a.cid < b.cid
      }
      return Self(id: k, title: first.collectionTitle ?? first.title, parts: sorted)
    }
  }
}
