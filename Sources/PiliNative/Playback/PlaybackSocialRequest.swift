import Foundation

/// Only a specific, currently selected archive/episode can supply these mutation parameters.
struct PlaybackSocialRequest: Equatable {
  let path: String, fields: [String: String]
  init(_ path: String, _ fields: [String: String]) {
    self.path = path
    self.fields = fields
  }
  static func like(_ item: EngagementItem, on: Bool) throws -> Self {
    guard ArchiveNumber.av(item.bvid) != nil else { throw ServiceError("没有可点赞的稿件") }
    return .init("/x/web-interface/archive/like", ["bvid": item.bvid, "like": on ? "1" : "2"])
  }
  static func coin(_ item: EngagementItem, amount: Int, already: Int, withLike: Bool) throws -> Self
  {
    guard amount > 0, already >= 0, already <= item.maxCoins, amount <= item.maxCoins - already
    else { throw ServiceError("达到投币上限") }
    var f = ["multiply": String(amount), "select_like": withLike ? "1" : "0"]
    if let aid = item.aid, aid > 0 {
      f["aid"] = String(aid)
    } else if ArchiveNumber.av(item.bvid) != nil {
      f["bvid"] = item.bvid
    } else {
      throw ServiceError("没有可投币的稿件")
    }
    return .init("/x/web-interface/coin/add", f)
  }
  static func triple(_ item: EngagementItem) throws -> Self {
    if let e = item.episode, e > 0 {
      return .init("/pgc/season/episode/like/triple", ["ep_id": String(e)])
    }
    guard let aid = item.aid ?? ArchiveNumber.av(item.bvid), aid > 0 else {
      throw ServiceError("没有可三连的稿件")
    }
    return .init("/x/web-interface/archive/like/triple", ["aid": String(aid)])
  }
  static func later(_ item: EngagementItem, removing: Bool) throws -> Self {
    guard let aid = ArchiveNumber.av(item.bvid), item.aid == nil || item.aid == aid else {
      throw ServiceError("稿件编号无效")
    }
    return removing
      ? .init("/x/v2/history/toview/v2/dels", ["resources": String(aid)])
      : .init("/x/v2/history/toview/add", ["bvid": item.bvid])
  }
}
