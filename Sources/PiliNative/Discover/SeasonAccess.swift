import Foundation

extension BiliAPI {
  /// Entitlements belong to the playback identity; watch history belongs to the history identity.
  func seasonOverview(_ id: Int64, byEpisode: Bool, history: String, viewer: String) async throws
    -> SeasonInfo
  {
    guard id > 0 else { throw ServiceError("作品编号无效") }
    let q = [byEpisode ? "ep_id" : "season_id": String(id)]
    let path = "/pgc/view/web/season"
    async let historyProgress = seasonHistory(path, fields: q, owner: viewer != history ? history : nil)
    struct Packet: Decodable { let code: Int, message: String?, result: SeasonInfo? }
    let body = try await fetch(
      path, q, host: "api.bilibili.com", expectedAccount: viewer, cacheVideoIdentity: true)
    let packet = try JSONDecoder().decode(Packet.self, from: body)
    guard packet.code == 0, var data = packet.result, let sid = data.season_id, sid > 0,
      byEpisode || sid == id
    else { throw ServiceError(packet.message ?? "作品暂不可用") }
    if viewer != history {
      data.usesHistoryOwner = true
      // Read history alone. Never replace the viewer's rights / episode list with another identity's copy.
      let progress = await historyProgress
      try Task.checkCancellation()
      data.historyProgress = progress
    }
    return data
  }
  private func seasonHistory(_ path: String, fields: [String: String], owner: String?) async
    -> SeasonInfo.User.Progress? {
    guard let owner else { return nil }
    struct History: Decodable { let user_status: SeasonInfo.User? }
    return (try? await read(path, fields, expectedAccount: owner, as: History.self))?.user_status?.progress
  }
  func catalogEpisode(_ e: SeasonInfo.Episode, history: String) async throws -> SeasonInfo.Episode {
    if e.canRequestPlayback { return e }
    guard e.canResolveCID else { throw ServiceError(e.accessReason ?? "此集暂不可播放") }
    var q = [String: String]()
    if let aid = e.aid, aid > 0 { q["aid"] = String(aid) }
    if !e.bvid.isEmpty { q["bvid"] = e.bvid }
    struct Part: Decodable { let cid: Int64, page: Int? }
    let parts = try await read("/x/player/pagelist", q, expectedAccount: history, as: [Part].self)
    // For an explicit part, never substitute an unrelated part.
    let match =
      e.page.flatMap { n in parts.first { $0.page == n } } ?? (e.page == nil ? parts.first : nil)
    guard let cid = match?.cid, cid > 0 else { throw ServiceError("未找到本集分段") }
    var row = e
    row.cid = cid
    return row
  }
}
