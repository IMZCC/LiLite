import Foundation
import XCTest

@testable import PiliWire

final class IMHistoryTests: XCTestCase {
  func testDirectConversationUsesDescendingCursorAndPageEmotes() async throws {
    let api = IMGateway { method, frame in
      XCTAssertEqual(method.path, "/bilibili.im.interface.v1.ImInterface/SyncFetchSessionMsgs")
      let q = try PiliBilibiliImInterfacesV1_ReqSessionMsg(serializedBytes: frame.dropFirst(5))
      XCTAssertEqual(q.sessionType, 1)
      XCTAssertEqual(q.talkerID, 123)
      XCTAssertEqual(q.size, 20)
      XCTAssertEqual(q.endSeqno, 110)
      XCTAssertEqual(q.beginSeqno, 0)
      XCTAssertEqual(q.devID, "1")
      var reply = PiliBilibiliImInterfacesV1_RspSessionMsg()
      var m = PiliBilibiliImType_Msg()
      m.senderUid = 123
      m.msgKey = -1
      m.msgType = 1
      m.msgStatus = 1
      m.msgSeqno = 100
      var e = PiliBilibiliImInterfacesV1_EmotionInfo()
      e.text = "[笑]"
      e.size = 2
      e.gifURL = "//i0.hdslb.com/a.gif"
      reply.messages = [m]
      reply.eInfos = [e]
      reply.minSeqno = 100
      reply.hasMore_p = 1
      return .init(
        status: 200, contentType: "application/grpc", headers: ["grpc-status": "0"],
        data: try WireFrame.encode(reply.serializedData()))
    }
    let list = try await api.history(talker: 123, before: 110)
    XCTAssertEqual(list.minSeqno, 100)
    XCTAssertEqual(list.messages.first?.msgKey, -1)
    XCTAssertEqual(list.messages.first?.msgStatus, 1)
    XCTAssertEqual(list.eInfos.first?.text, "[笑]")
  }
}
