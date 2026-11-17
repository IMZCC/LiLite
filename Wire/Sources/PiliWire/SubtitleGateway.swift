import Foundation
import SwiftProtobuf

public enum SubtitleGateway {
  public static let path = "/bilibili.community.service.dm.v1.DM/DmView"
  public struct Track: Sendable {
    public let id: String, language: String, name: String, url: String, ai: Bool
  }
  public static func tracks(
    aid: Int64, cid: Int64, exchange: @Sendable (Data) async throws -> GatewayReply
  ) async throws -> [Track] {
    guard aid > 0, cid > 0 else { return [] }
    var q = PiliBilibiliCommunityServiceDmV1_DmViewReq()
    q.pid = aid
    q.oid = cid
    q.type = 1
    let frame = try WireFrame.encode(q.serializedData())
    let reply = try PiliBilibiliCommunityServiceDmV1_DmViewReply(
      serializedBytes: WireFrame.decode(try await exchange(frame)))
    return reply.subtitle.subtitles.map { row in
      Track(
        id: row.idStr.isEmpty ? (row.id > 0 ? String(row.id) : "") : row.idStr, language: row.lan,
        name: row.lanDoc, url: row.subtitleURL, ai: row.type == .ai)
    }
  }
}
