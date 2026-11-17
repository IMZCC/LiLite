import Foundation
import UIKit

enum OfflineAttachment: String, CaseIterable, Identifiable {
  case all = "更新全部附件"
  case comments = "更新弹幕"
  case captions = "更新字幕"
  case segments = "更新空降片段"
  case art = "更新封面"
  case minimal = "封面与片段"
  var id: Self { self }
}
extension OfflineExtras {
  struct LocalMarker: Codable {
    let category: String, actionType: String?, segment: [Double], uuid: String
    init(_ s: SponsorSegment) {
      category = s.category
      actionType = s.actionType
      segment = s.segment
      uuid = s.id
    }
    var segmentInfo: SponsorSegment {
      .init(category: category, actionType: actionType, segment: segment, UUID: uuid)
    }
  }
  static func authorize(_ v: OfflineVideo) async throws {
    guard let owner = v.cacheOwner,
      (try await AccountJar.shared.localOwner(.role(.video)) ?? "") == owner
    else { throw ServiceError("视频账号已切换") }
    try Task.checkCancellation()
  }
  static func updateCover(_ v: OfflineVideo, dir: URL) async throws {
    guard let u = v.cover.flatMap(httpsURL) else { return }
    try await authorize(v)
    let img = try await ArtworkStore.shared.image(u, pixels: 640, maximum: 4 * 1024 * 1024)
    guard let bytes = img.jpegData(compressionQuality: 0.85) else { throw ServiceError("封面读取失败") }
    try await authorize(v)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try bytes.write(to: dir.appendingPathComponent("cover.jpg"), options: .atomic)
  }
  static func updateMarkers(_ v: OfflineVideo, dir: URL) async throws {
    try await authorize(v)
    let rows = try await SponsorAPI().segments(v.bvid, v.cid).filter(\.valid)
    let bytes = try JSONEncoder().encode(rows.map(LocalMarker.init))
    try await authorize(v)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try bytes.write(to: dir.appendingPathComponent("markers.json"), options: .atomic)
  }
  static func markers(_ dir: URL) async -> [SponsorSegment] {
    let file = dir.appendingPathComponent("markers.json")
    guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= 8 * 1024 * 1024,
      let bytes = try? Data(contentsOf: file),
      let rows = try? JSONDecoder().decode([LocalMarker].self, from: bytes)
    else { return [] }
    return rows.map(\.segmentInfo).filter(\.valid)
  }
}
