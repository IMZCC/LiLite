import Foundation
import SwiftProtobuf

public struct ListenerGateway: Sendable {
  public enum Method: String, Sendable {
    case playlist = "Playlist"
    case playURL = "PlayURL"
    case thumb = "ThumbUp"
    case triple = "TripleLike"
    case coin = "CoinAdd"
    public var path: String { "/bilibili.app.listener.v1.Listener/" + rawValue }
    public var reads: Bool { self == .playlist || self == .playURL }
  }
  public typealias Exchange = @Sendable (Method, Data) async throws -> GatewayReply
  public typealias Track = PiliBilibiliAppListenerV1_PlayItem
  public typealias Row = PiliBilibiliAppListenerV1_DetailItem
  public typealias Playlist = PiliBilibiliAppListenerV1_PlaylistResp
  public typealias Media = PiliBilibiliAppListenerV1_PlayInfo
  private let exchange: Exchange
  public init(_ exchange: @escaping Exchange) { self.exchange = exchange }
  public static func item(oid: Int64, sub: Int64, type: Int32) -> Track {
    var i = Track()
    i.oid = oid
    i.itemType = type
    i.subID = [sub]
    return i
  }
  private static var args: PiliBilibiliAppArchiveMiddlewareV1_PlayerArgs {
    var a = PiliBilibiliAppArchiveMiddlewareV1_PlayerArgs()
    a.qn = 80
    a.fnval = 4048
    a.forceHost = 2
    a.voiceBalance = 1
    return a
  }
  private func call<Q: SwiftProtobuf.Message, R: SwiftProtobuf.Message>(
    _ m: Method, _ q: Q, _ type: R.Type
  ) async throws -> R {
    let d = try WireFrame.encode(q.serializedData())
    return try R(serializedBytes: WireFrame.decode(try await exchange(m, d)))
  }
  public func playlist(
    id: Int64, source: Int, extra: Int64?, anchor: Track, order: Int, cursor: String?
  ) async throws -> Playlist {
    var q = PiliBilibiliAppListenerV1_PlaylistReq()
    q.id = id
    q.extraID = extra ?? 0
    q.playerArgs = Self.args
    q.pagination.pageSize = 20
    q.sortOpt.order = PiliBilibiliAppListenerV1_ListOrder(rawValue: order) ?? .orderNormal
    if let cursor {
      q.pagination.next = cursor
      q.anchor = Track()
    } else {
      q.from = .init(rawValue: source) ?? .upArchive
      q.anchor = anchor
    }
    return try await call(.playlist, q, Playlist.self)
  }
  public func media(_ item: Track) async throws -> Media {
    var q = PiliBilibiliAppListenerV1_PlayURLReq()
    q.item = item
    q.playerArgs = Self.args
    let r = try await call(.playURL, q, PiliBilibiliAppListenerV1_PlayURLResp.self)
    guard let part = item.subID.first,
      let info = r.playerInfo[part]
        ?? (r.playerInfo.count == 1 && r.item.oid == item.oid && r.item.subID == item.subID
          ? r.playerInfo.values.first : nil)
    else {
      if !r.message.isEmpty { throw WireError.remote(9, r.message) }
      throw WireError.invalid("没有返回所选分集的听视频音轨")
    }
    guard info.code == 0 else { throw WireError.remote(Int(info.code), info.message) }
    return info
  }
  public enum Action: Equatable, Sendable {
    case like(Bool)
    case coin(Int32, Bool)
    case triple
  }
  public struct Receipt: Sendable { public let message: String, like: Bool, coin: Bool, fav: Bool }
  public func update(_ action: Action, item: Track) async throws -> Receipt {
    switch action {
    case .like(let value):
      var q = PiliBilibiliAppListenerV1_ThumbUpReq()
      q.item = item
      q.action = value ? .like : .cancelLike
      let r = try await call(.thumb, q, PiliBilibiliAppListenerV1_ThumbUpResp.self)
      return .init(message: r.message, like: value, coin: false, fav: false)
    case .coin(let n, let linked):
      guard (1...2).contains(n) else { throw WireError.invalid("只支持投 1 或 2 个硬币") }
      var q = PiliBilibiliAppListenerV1_CoinAddReq()
      q.item = item
      q.num = n
      q.thumbUp = linked
      let r = try await call(.coin, q, PiliBilibiliAppListenerV1_CoinAddResp.self)
      return .init(message: r.message, like: linked, coin: true, fav: false)
    case .triple:
      var q = PiliBilibiliAppListenerV1_TripleLikeReq()
      q.item = item
      let r = try await call(.triple, q, PiliBilibiliAppListenerV1_TripleLikeResp.self)
      return .init(message: r.message, like: r.thumbOk, coin: r.coinOk, fav: r.favOk)
    }
  }
}
