import Foundation
import XCTest

@testable import PiliWire

final class IMConversationActionTests: XCTestCase {
  func testExactPeerStateAndReadSequence() async throws {
    var peer = PiliIM_SessionId()
    peer.privateID.talkerUid = 42
    let subject = peer
    let gateway = IMGateway { m, bytes in
      let payload: Data
      if m == .update {
        XCTAssertEqual(m.path, "/bilibili.app.im.v1.im/SessionUpdate")
        let q = try PiliIM_SessionUpdateReq(serializedBytes: bytes.dropFirst(5))
        XCTAssertEqual(q.sessionID, subject)
        var s = PiliIM_SessionUpdateReply()
        s.session.id = subject
        s.session.isPinned = true
        payload = try s.serializedData()
      } else {
        XCTAssertEqual(m.path, "/bilibili.im.interface.v1.ImInterface/SessionDetail")
        let q = try PiliBilibiliImInterfacesV1_ReqSessionDetail(serializedBytes: bytes.dropFirst(5))
        XCTAssertEqual(q.talkerID, 42)
        XCTAssertEqual(q.sessionType, 1)
        var r = PiliBilibiliImType_SessionInfo()
        r.talkerID = 42
        r.sessionType = 1
        r.ackSeqno = 88
        payload = try r.serializedData()
      }
      return .init(
        status: 200, contentType: "application/grpc", headers: ["grpc-status": "0"],
        data: try WireFrame.encode(payload))
    }
    let state = try await gateway.session(subject)
    let seq = try await gateway.readSequence(talker: 42)
    XCTAssertTrue(state.isPinned)
    XCTAssertEqual(seq, 88)
    let mismatched = IMGateway { _, _ in
      var r = PiliBilibiliImType_SessionInfo()
      r.talkerID = 9
      r.sessionType = 1
      r.ackSeqno = 11
      return .init(
        status: 200, contentType: "application/grpc", headers: ["grpc-status": "0"],
        data: try WireFrame.encode(r.serializedData()))
    }
    do {
      _ = try await mismatched.readSequence(talker: 42)
      XCTFail("wrong peer")
    } catch {}
  }
  func testImageAndRecallUseSendMsgAndRequireReceipt() async throws {
    for (type, body) in [
      (Int32(2), #"{"url":"https://example.test/pic","width":20,"height":10}"#),
      (5, "18446744073709551610"),
    ] {
      let g = IMGateway { method, frame in
        XCTAssertEqual(method, .send)
        let q = try PiliBilibiliImInterfacesV1_ReqSendMsg(serializedBytes: frame.dropFirst(5))
        XCTAssertEqual(q.msg.senderUid, 7)
        XCTAssertEqual(q.msg.receiverID, 8)
        XCTAssertEqual(q.msg.receiverType, 1)
        XCTAssertEqual(q.msg.content, body)
        XCTAssertEqual(q.msg.msgType, type)
        var r = PiliBilibiliImInterfacesV1_RspSendMsg()
        r.msgKey = 99
        return .init(
          status: 200, contentType: "application/grpc", headers: ["grpc-status": "0"],
          data: try WireFrame.encode(r.serializedData()))
      }
      try await g.sendCardOrNote(sender: 7, to: 8, kind: type, content: body)
    }
    let empty = IMGateway { m, _ in
      XCTAssertNotEqual(m, .send, "invalid recall must never send")
      return .init(
        status: 200, contentType: "application/grpc", headers: ["grpc-status": "0"],
        data: try WireFrame.encode(Data()))
    }
    do {
      try await empty.sendCardOrNote(sender: 7, to: 8, kind: 5, content: "broken")
      XCTFail("invalid key")
    } catch {}
  }
}
