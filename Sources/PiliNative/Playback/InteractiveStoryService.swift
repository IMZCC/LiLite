import Foundation

extension StoryReader {
  static let site = Self(positions: { bvid, cid, owner in
    let api = BiliAPI.shared
    let q = try await api.sign(["bvid": bvid, "cid": String(cid)])
    return try await api.read("/x/player/wbi/v2", q, expectedAccount: owner, as: VideoPositions.self)
  }, edge: { bvid, version, edge, owner in
    var fields = ["bvid": bvid, "graph_version": String(version)]
    fields["edge_id"] = edge.map(String.init)
    return try await BiliAPI.shared.read("/x/stein/edgeinfo_v2", fields, expectedAccount: owner, as: StoryNode.self)
  })
}
extension PlayerModel: StoryOutput {
  func storyChapters(_ chapters: [VideoPositions.Chapter], bvid: String, cid: Int64) {
    timeline.updateChapters(chapters, bvid: bvid, cid: cid)
  }
}
