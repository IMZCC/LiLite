import Foundation

/// The server's progressive/legacy alternative to DASH, including its original ordered parts.
struct LegacyDURLBody: Decodable {
  struct Part: Decodable {
    enum CodingKeys: String, CodingKey { case url, backup_url, order, length }
    let url: String
    let backup_url: [String]?
    let order: Int?
    let length: Double?
    var selected: URL? = nil
    var originals: [URL] { ([url] + (backup_url ?? [])).compactMap(httpsURL) }
    var routes: [URL] { selected.map { [$0] } ?? VODLine.current(originals) }
  }
  let durl: [Part]?
  let quality: Int?
  let accept_quality: [Int]?
  let language: SpokenCatalog?
  let cur_language: String?
  let volume: AudioMeasurements?
  var parts: [Part] {
    get throws {
      guard let durl, !durl.isEmpty, durl.count <= 256 else { throw ServiceError("没有可播放的视频片段") }
      let ordered = durl.enumerated().sorted { ($0.element.order ?? $0.offset + 1) < ($1.element.order ?? $1.offset + 1) }
      var seen = Set<Int>()
      for (offset, part) in ordered {
        guard seen.insert(part.order ?? offset + 1).inserted, !part.routes.isEmpty,
          part.length.map({ $0.isFinite && $0 > 0 && $0 <= 7 * 86400 * 1000 }) ?? true
        else { throw ServiceError("视频片段信息无效") }
      }
      return ordered.map(\.element)
    }
  }
}
struct LegacyDURLPlan {
  let body: LegacyDURLBody, reference: URL, owner: String, preview: Bool
}
