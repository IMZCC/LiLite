import Foundation
import SwiftProtobuf
import XCTest

@testable import PiliWire

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class ReplyGatewayTests: XCTestCase {
  func testDeviceMetadataKeepsGuestAndAccountSeparate() throws {
    func open(_ fields: [String: String]) throws -> (
      PiliBilibiliMetadata_Metadata, PiliBilibiliMetadataDevice_Device
    ) {
      let m = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(fields["x-bili-metadata-bin"])))
      let d = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(fields["x-bili-device-bin"])))
      return (try .init(serializedBytes: m), try .init(serializedBytes: d))
    }
    let guest = try open(
      ClientMetadata.headers(device: "device-A", token: nil, build: 1, version: "1.0"))
    let signed = try open(
      ClientMetadata.headers(device: "device-B", token: "test-only", build: 2, version: "2.0"))
    XCTAssertEqual(guest.0.accessKey, "")
    XCTAssertEqual(guest.1.buvid, "device-A")
    XCTAssertEqual(signed.0.accessKey, "test-only")
    XCTAssertEqual(signed.0.buvid, signed.1.buvid)
    XCTAssertEqual(signed.1.buvid, "device-B")
    XCTAssertEqual(signed.1.platform, "android")
    XCTAssertEqual(signed.0.mobiApp, "android_hd")
  }
  func testPresentZeroAndEmptyGoodsFieldsRemainDistinguishable() throws {
    typealias Extra = PiliBilibiliMainCommunityReplyV1_Url.Extra
    let none = try Extra(serializedBytes: Data())
    let zero = try Extra(serializedBytes: Data([0x08, 0x00]))
    let empty = try Extra(serializedBytes: Data([0x12, 0x00]))
    XCTAssertFalse(none.hasGoodsItemID || none.hasGoodsPrefetchedCache)
    XCTAssertTrue(zero.hasGoodsItemID && !zero.hasGoodsPrefetchedCache)
    XCTAssertTrue(empty.hasGoodsPrefetchedCache && !empty.hasGoodsItemID)
    XCTAssertEqual(try zero.serializedData(), Data([0x08, 0x00]))
    XCTAssertEqual(try empty.serializedData(), Data([0x12, 0x00]))
  }
  private static func response<T: Message>(_ value: T) throws -> GatewayReply {
    .init(
      status: 200, contentType: "application/grpc", headers: ["grpc-status": "0"],
      data: try WireFrame.encode(value.serializedData()))
  }
  func testAnchorPinFoldDetailDialogueAndLookup() async throws {
    let id = Int64.max - 100
    let api = ReplyGateway { m, frame in
      let bytes = frame.dropFirst(5)
      var row = ReplyGateway.Row()
      row.id = id
      row.content.message = "原文"
      switch m {
      case .main:
        let q = try PiliBilibiliMainCommunityReplyV1_MainListReq(serializedBytes: bytes)
        XCTAssertEqual(q.rpid, q.hasPagination ? 0 : id)
        if q.hasPagination { XCTAssertEqual(q.pagination.offset, "page2") }
        XCTAssertEqual(q.mode, .mainListHot)
        var r = PiliBilibiliMainCommunityReplyV1_MainListReply()
        r.upTop = row
        r.replies = [row]
        r.subjectControl.count = 50
        r.voteCard.voteID = id - 1
        r.voteCard.title = "最喜欢哪一集"
        r.voteCard.count = 35
        var card = PiliBilibiliMainCommunityReplyV1_MixedCard()
        card.fold.bottomText = "更多"
        card.fold.foldPagination.offset = "opaque +/="
        card.fold.foldPagination.pageSize = 7
        r.mixedCards = [card]
        r.paginationReply.nextOffset = "page2"
        return try Self.response(r)
      case .folded:
        let q = try PiliBilibiliMainCommunityReplyV1_FoldListReq(serializedBytes: bytes)
        XCTAssertEqual(q.pagination.pageSize, 7)
        XCTAssertEqual(q.pagination.offset, "opaque +/=")
        var r = PiliBilibiliMainCommunityReplyV1_FoldListResp()
        r.replies = [row]
        r.paginationReply.nextOffset = q.pagination.offset
        return try Self.response(r)
      case .detail:
        let q = try PiliBilibiliMainCommunityReplyV1_DetailListReq(serializedBytes: bytes)
        XCTAssertEqual(q.root, 15)
        XCTAssertEqual(q.rpid, q.hasPagination ? 0 : id)
        XCTAssertEqual(q.mode, .mainListTime)
        var r = PiliBilibiliMainCommunityReplyV1_DetailListReply()
        r.root.id = 15
        r.root.replies = [row]
        r.cursor.isEnd = q.hasPagination
        r.paginationReply.nextOffset = "next"
        return try Self.response(r)
      case .dialogue:
        let q = try PiliBilibiliMainCommunityReplyV1_DialogListReq(serializedBytes: bytes)
        XCTAssertEqual(q.dialog, 91)
        XCTAssertEqual(q.root, 15)
        var r = PiliBilibiliMainCommunityReplyV1_DialogListReply()
        r.replies = [row]
        return try Self.response(r)
      case .translate:
        let q = try PiliBilibiliMainCommunityReplyV1_TranslateReplyReq(serializedBytes: bytes)
        XCTAssertEqual(q.rpids, [id])
        row.translatedContent.message = "译文"
        var r = PiliBilibiliMainCommunityReplyV1_TranslateReplyResp()
        r.translatedReplies = [id: row]
        return try Self.response(r)
      case .search:
        let q = try PiliBilibiliMainCommunityReplyV1_SearchItemReq(serializedBytes: bytes)
        XCTAssertTrue(q.cursor.itemType == .article || q.cursor.itemType == .video)
        XCTAssertEqual(q.keyword, "猫")
        XCTAssertEqual(q.cursor.next, 2)
        var r = PiliBilibiliMainCommunityReplyV1_SearchItemReply()
        var item = PiliBilibiliMainCommunityReplyV1_SearchItem()
        if q.cursor.itemType == .article {
          item.article.title = "猫"
          item.url = "https://www.bilibili.com/read/cv1"
        } else {
          item.video.ugc.title = "猫片"
          item.video.ugc.duration = 60
          item.url = "https://www.bilibili.com/video/av1"
        }
        r.items = [item]
        r.cursor.hasNext_p = true
        r.cursor.next = 4
        return try Self.response(r)
      }
    }
    let main = try await api.list(oid: 5, type: 1, thread: .main(anchor: id), newest: false)
    XCTAssertEqual(main.rows.map(\.id), [id])
    XCTAssertEqual(main.next, "page2")
    XCTAssertEqual(main.subject?.count, 50)
    XCTAssertEqual(main.vote?.id, id - 1)
    XCTAssertEqual(main.vote?.title, "最喜欢哪一集")
    XCTAssertEqual(main.vote?.count, 35)
    let nextMain = try await api.list(
      oid: 5, type: 1, thread: .main(anchor: id), newest: false, offset: "page2")
    XCTAssertNil(nextMain.vote)
    let fold = try XCTUnwrap(main.fold)
    let folded = try await api.list(
      oid: 5, type: 1, thread: .folded(fold.pagination), newest: false)
    XCTAssertNil(folded.next)
    XCTAssertEqual(folded.rows.map(\.id), [id])
    let detail = try await api.list(
      oid: 5, type: 1, thread: .detail(root: 15, anchor: id), newest: true)
    XCTAssertEqual(detail.rows.map(\.id), [15, id])
    let more = try await api.list(
      oid: 5, type: 1, thread: .detail(root: 15, anchor: id), newest: true, offset: detail.next)
    XCTAssertEqual(more.rows.map(\.id), [id])
    XCTAssertNil(more.next)
    let dialogue = try await api.list(
      oid: 5, type: 1, thread: .dialogue(root: 15, id: 91), newest: true)
    XCTAssertEqual(dialogue.rows.map(\.id), [id])
    let translated = try await api.translation(oid: 5, type: 1, id: id)
    XCTAssertEqual(translated.message, "译文")
    let references = try await api.references(oid: 5, type: 1, article: true, keyword: "猫", page: 2)
    XCTAssertEqual(references.items.first?.title, "猫")
    XCTAssertEqual(references.next, 4)
    let videos = try await api.references(oid: 5, type: 1, article: false, keyword: "猫", page: 2)
    XCTAssertEqual(videos.items.first?.duration, 60)
  }
  func testRichArchivePreservesIDsAndIgnoresFutureFields() throws {
    let fixture = Data(
      #"{"id":"9223372036854775700","mid":"18","root":"22","parent":"24","futureMetadata":true,"member":{"name":"米","level":"5"},"content":{"message":"@米 [猫]","atNameToMid":{"米":"18"},"pictures":[{"imgSrc":"https://i0.hdslb.com/a.jpg","imgWidth":"3","imgHeight":"5"}]}}"#
        .utf8)
    let item = try ReplyGateway.archived(fixture)
    XCTAssertEqual(item.id, 9_223_372_036_854_775_700)
    XCTAssertEqual(item.parent, 24)
    XCTAssertEqual(item.member.name, "米")
    XCTAssertEqual(item.content.atNameToMid["米"], 18)
    XCTAssertEqual(item.content.pictures.first?.imgHeight, 5)
  }
  func testPublicGuestDiscussion() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["PILI_PUBLIC_REPLY"] == "1")
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.timeoutIntervalForRequest = 20
    let session = URLSession(configuration: config)
    defer { session.finishTasksAndInvalidate() }
    let api = ReplyGateway { method, data in
      var q = URLRequest(url: URL(string: "https://app.bilibili.com" + method.path)!)
      q.httpMethod = "POST"
      q.httpBody = data
      q.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
      q.setValue("identity,gzip", forHTTPHeaderField: "grpc-accept-encoding")
      q.setValue("PiliNative/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
      let (bytes, res) = try await session.data(for: q)
      let h = try XCTUnwrap(res as? HTTPURLResponse)
      let headers = Dictionary(
        uniqueKeysWithValues: ["grpc-status", "grpc-message", "grpc-encoding"].compactMap { k in
          h.value(forHTTPHeaderField: k).map { (k, $0) }
        })
      print(
        "Guest \(method.rawValue): HTTP \(h.statusCode); gRPC \(headers["grpc-status"] ?? "not supplied"); \(bytes.count) bytes"
      )
      return .init(
        status: h.statusCode, contentType: h.mimeType ?? "", headers: headers, data: bytes)
    }
    let page = try await api.list(oid: 170001, type: 1, thread: .main(anchor: nil), newest: false)
    XCTAssertFalse(page.rows.isEmpty)
    print("Guest main: \(page.rows.count) rows; next \(page.next != nil); fold \(page.fold != nil)")
    if let root = page.rows.first(where: { $0.count > 0 }) {
      let detail = try await api.list(
        oid: 170001, type: 1, thread: .detail(root: root.id, anchor: nil), newest: true)
      XCTAssertEqual(detail.rows.first?.id, root.id)
      print("Guest detail: \(detail.rows.count) rows")
      if let child = detail.rows.last, child.id != root.id {
        let anchor = try await api.list(
          oid: 170001, type: 1, thread: .detail(root: root.id, anchor: child.id), newest: false)
        XCTAssertTrue(anchor.rows.contains(where: { $0.id == child.id }))
        print("Guest anchor: matched requested child")
      }
      if let child = detail.rows.first(where: { $0.dialog > 0 && $0.dialog != $0.id && $0.root > 0 }
      ) {
        let dialog = try await api.list(
          oid: 170001, type: 1, thread: .dialogue(root: root.id, id: child.dialog), newest: true)
        XCTAssertFalse(dialog.rows.isEmpty)
        print("Guest dialogue: \(dialog.rows.count) rows")
      }
    }
  }
}
