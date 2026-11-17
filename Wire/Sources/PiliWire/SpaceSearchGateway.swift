import Foundation
import SwiftProtobuf

public enum SpaceSearchGateway {
  public static let path = "/bilibili.app.interface.v1.Space/SearchArchive"
  public static func page(
    mid: Int64, term: String, number: Int, exchange: @Sendable (Data) async throws -> GatewayReply
  ) async throws -> PiliBilibiliAppInterfacesV1_SearchArchiveReply {
    guard mid > 0, number > 0, number <= 10_000_000, !term.isEmpty, term.utf8.count <= 2048 else {
      throw WireError.invalid("空间搜索条件无效")
    }
    var request = PiliBilibiliAppInterfacesV1_SearchArchiveReq()
    request.keyword = term
    request.mid = mid
    request.pn = Int64(number)
    request.ps = 20
    let data = try WireFrame.encode(request.serializedData())
    return try PiliBilibiliAppInterfacesV1_SearchArchiveReply(serializedBytes: WireFrame.decode(try await exchange(data)))
  }
}
