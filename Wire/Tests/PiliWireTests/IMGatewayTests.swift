import Foundation
import XCTest

@testable import PiliWire

final class IMGatewayTests: XCTestCase {
  // Byte fixtures use the field numbers in the pinned SessionSecondary* and PaginationParams descriptors.
  private let offsetA: [UInt8] = [10, 8, 8, 2, 18, 4, 8, 21, 16, 17]
  private func ok(_ payload: [UInt8]) throws -> GatewayReply {
    .init(
      status: 200, contentType: "application/grpc", headers: ["Grpc-Status": "0"],
      data: try WireFrame.encode(Data(payload)))
  }
  func testOffsetsAndClassification() async throws {
    let maps = offsetA + [10, 6, 8, 3, 18, 2, 8, 77]
    let response = try ok(
      [10, UInt8(maps.count + 2)] + maps + [16, 1, 26, 6, 10, 4, 10, 2, 8, 42])
    let first = IMGateway { m, d in
      XCTAssertEqual(m, .secondary)
      XCTAssertEqual(Array(d.dropFirst(5)), [18, 0, 24, 4])
      return response
    }
    let p = try await first.sessions(.dustbin)
    XCTAssertEqual(p.rows.first?.id.privateID.talkerUid, 42)
    let cursor = try XCTUnwrap(p.cursor)
    let second = IMGateway { method, d in
      XCTAssertEqual(method, .secondary)
      let r = try PiliIM_SessionSecondaryReq(serializedBytes: d.dropFirst(5))
      XCTAssertEqual(r.pageType, .dustbin)
      XCTAssertEqual(r.paginationParams.offsets[2]?.topOffset, 17)
      XCTAssertEqual(r.paginationParams.offsets[3]?.normalOffset, 77)
      XCTAssertFalse(r.paginationParams.hasMore_p)
      return response
    }
    let repeated = try await second.sessions(.dustbin, cursor: cursor)
    XCTAssertNil(repeated.cursor)
  }
  func testSharedWireStatusAndEnvelope() throws {
    for r in [
      GatewayReply(
        status: 200, contentType: "application/grpc", headers: [:],
        data: Data(repeating: 0, count: 5)),
      .init(
        status: 200, contentType: "application/grpc", headers: ["grpc-status": "16"],
        data: Data(repeating: 0, count: 5)),
      .init(
        status: 200, contentType: "text/html", headers: ["grpc-status": "0"],
        data: Data(repeating: 0, count: 5)),
      .init(
        status: 200, contentType: "application/grpc", headers: ["grpc-status": "0"],
        data: Data([0, 0, 0, 0, 4, 1])),
      .init(
        status: 200, contentType: "application/grpc", headers: ["grpc-status": "0"],
        data: Data(repeating: 0, count: 10)),
    ] { XCTAssertThrowsError(try WireFrame.decode(r)) }
    // A gzip member containing the ASCII string "abc".
    let bytes: [UInt8] = [
      31, 139, 8, 0, 0, 0, 0, 0, 0, 3, 75, 76, 74, 6, 0, 194, 65, 36, 53, 3, 0, 0, 0,
    ]
    let gzip = GatewayReply(
      status: 200, contentType: "application/grpc",
      headers: ["grpc-status": "0", "grpc-encoding": "gzip"], data: Data([1, 0, 0, 0, 23] + bytes))
    XCTAssertEqual(try WireFrame.decode(gzip), Data("abc".utf8))
  }
  func testScopedMutationsAndServerLimits() async throws {
    let recorded = Recorder()
    let g = IMGateway { m, d in
      await recorded.put(m, Data(d.dropFirst(5)))
      let reply: [UInt8] = m == .keywords ? [10, 4, 10, 2, 104, 105, 16, 20, 24, 12] : []
      return .init(
        status: 200, contentType: "application/grpc", headers: ["grpc-status": "0"],
        data: try WireFrame.encode(Data(reply)))
    }
    let keywords = try await g.keywords()
    XCTAssertEqual(keywords.items.map(\.keyword), ["hi"])
    XCTAssertEqual(keywords.charLimit, 12)
    try await g.keyword("xy", add: true)
    try await g.keyword("xy", add: false)
    try await g.clearUnread(.unfollowed)
    try await g.deleteSessions(.dustbin)
    let calls = await recorded.calls
    XCTAssertEqual(calls.map(\.0), [.keywords, .addKeyword, .deleteKeyword, .clear, .delete])
    XCTAssertEqual(calls[1].1, Data([10, 2, 120, 121]))
    XCTAssertEqual(try PiliIM_DeleteSessionListReq(serializedBytes: calls[4].1).pageType, .dustbin)
  }
  func testShareCardUsesOwnMethodAndRequiresMessageKey() async throws {
    let acknowledged = try ok([8, 42])
    let missing = try ok([])
    let api = IMGateway { method, frame in
      XCTAssertEqual(method.path, "/bilibili.im.interface.v1.ImInterface/SendMsg")
      let q = try PiliBilibiliImInterfacesV1_ReqSendMsg(serializedBytes: Data(frame.dropFirst(5)))
      XCTAssertEqual(q.msg.senderUid, 8)
      XCTAssertEqual(q.msg.receiverID, 42)
      XCTAssertEqual(q.msg.receiverType, 1)
      XCTAssertEqual(q.msg.msgType, 7)
      XCTAssertFalse(q.devID.isEmpty)
      return acknowledged
    }
    try await api.sendCardOrNote(sender: 8, to: 42, kind: 7, content: "{}")
    do {
      try await IMGateway { _, _ in missing }.sendCardOrNote(
        sender: 8, to: 42, kind: 14, content: "{}")
      XCTFail("missing acknowledgement accepted")
    } catch {}
    let recipients = try await IMGateway { method, frame in
      XCTAssertEqual(method.path, "/bilibili.im.interface.v1.ImInterface/ShareList")
      XCTAssertEqual(Array(frame.dropFirst(5)), [8, 5])
      return missing
    }.shareContacts()
    XCTAssertTrue(recipients.isEmpty)
  }
  actor Recorder {
    var calls: [(IMGateway.Method, Data)] = []
    func put(_ m: IMGateway.Method, _ d: Data) { calls.append((m, d)) }
  }
}
