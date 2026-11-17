import Foundation

struct ArchiveSeasonSubscription: Equatable {
  let season: Int64, bvid: String, owner: String
  init?(item: Int64?, catalog: Int64?, bvid: String, owner: String) {
    guard ArchiveNumber.av(bvid) != nil, let actor = Int64(owner), actor > 0,
      String(actor) == owner,
      let id = item ?? catalog, id > 0, item == nil || catalog == nil || item == catalog
    else { return nil }
    season = id
    self.bvid = bvid
    self.owner = owner
  }
  struct Relation: Decodable {
    let season_fav: Bool?
    var following: Bool { season_fav ?? false }
  }
  func toggle(
    wasFollowing: Bool, active: String?,
    send: (String, [String: String], String) async throws -> Void
  ) async throws -> Bool {
    guard active == owner else { throw ServiceError("账号已切换") }
    try Task.checkCancellation()
    let path = wasFollowing ? "/x/v3/fav/season/unfav" : "/x/v3/fav/season/fav"
    try await send(path, ["platform": "web", "season_id": String(season)], owner)
    return !wasFollowing
  }
}
