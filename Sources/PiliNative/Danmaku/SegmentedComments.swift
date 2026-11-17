import Combine
import Foundation
import PiliWire

@MainActor final class BulletAvailability: ObservableObject {
  static let shared = BulletAvailability()
  private struct Key: Hashable { let owner: String, cid: Int64 }
  private struct Status { let time: Date, closed: Bool }
  @Published private var records = [Key: Status]()
  func status(_ cid: Int64, owner: String) -> Bool? {
    guard let s = records[.init(owner: owner, cid: cid)], Date().timeIntervalSince(s.time) < 180
    else { return nil }
    return s.closed
  }
  func closed(_ cid: Int64, owner: String) -> Bool { status(cid, owner: owner) == true }
  func observe(_ page: DMProto.Page, cid: Int64, owner: String) {
    let now = Date()
    records = records.filter { now.timeIntervalSince($0.value.time) < 180 }
    let key = Key(owner: owner, cid: cid)
    records[key] = Status(time: now, closed: page.closed)
    if records.count > 512, let oldest = records.min(by: { $0.value.time < $1.value.time })?.key {
      records[oldest] = nil
    }
  }
}
extension BiliAPI {
  func commentPage(cid: Int64, aid: Int64?, index: Int, expectedAccount: String? = nil) async throws
    -> DMProto.Page
  {
    let identity = try await AccountJar.shared.current(.role(.main))
    let owner = identity?.id ?? ""
    guard expectedAccount.map({ $0 == owner }) ?? true else { throw ServiceError("账号已切换") }
    let request = try DMProto.request(cid: cid, index: index)
    // A browser-only login uses its authorized web transport, never a guest identity in its place.
    var web = identity?.mobileToken?.isEmpty != false
    var result: DMProto.Page?
    if !web {
      let reply = try await mobileCall(
        "/bilibili.community.service.dm.v1.DM/DmSegMobile", try WireFrame.encode(request),
        uid: identity?.id, needsToken: false, readOnly: true)
      if [404, 405, 501].contains(reply.status)
        || (reply.status == 200 && reply.headers["grpc-status"] == "12")
      {
        web = true
      } else {
        result = try DMProto.page(WireFrame.decode(reply))
      }
    }
    if web {
      var q = ["type": "1", "oid": String(cid), "segment_index": String(index)]
      if let aid { q["pid"] = String(aid) }
      let bytes = try await fetch(
        "/x/v2/dm/web/seg.so", try await sign(q), host: "api.bilibili.com", expectedAccount: owner)
      // The web service may report a business failure inside HTTP 200.
      if bytes.first == 123 {
        struct Status: Decodable { let code: Int, message: String? }
        let s = try JSONDecoder().decode(Status.self, from: bytes)
        throw ServiceError(s.message ?? "无法读取弹幕", code: s.code)
      }
      result = try DMProto.page(bytes)
    }
    try Task.checkCancellation()
    let verify = try await AccountJar.shared.current(.role(.main))
    guard verify?.id == identity?.id, verify?.mobileToken == identity?.mobileToken, let result
    else { throw ServiceError("账号已切换") }
    await BulletAvailability.shared.observe(result, cid: cid, owner: owner)
    return result
  }
  func commentSegment(cid: Int64, aid: Int64?, index: Int, expectedAccount: String? = nil)
    async throws -> [Bullet]
  {
    try await commentPage(cid: cid, aid: aid, index: index, expectedAccount: expectedAccount).items
  }
}
