import Foundation
import XCTest

@testable import PiliWire

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class DynamicGatewayTests: XCTestCase {
  func testUnreadDynamicUsesOwnTabAndCount() async throws {
    let api = DynamicGateway { method, frame in
      XCTAssertEqual(method.path, "/bilibili.app.dynamic.v1.Dynamic/DynRed")
      let q = try PiliBilibiliAppDynamicV1_DynRedReq(serializedBytes: Data(frame.dropFirst(5)))
      XCTAssertEqual(q.tabOffset.map(\.tab), [1])
      var r = PiliBilibiliAppDynamicV1_DynRedReply()
      r.dynRedItem.count = 107
      return .init(
        status: 200, contentType: "application/grpc", headers: ["grpc-status": "0"],
        data: try WireFrame.encode(r.serializedData()))
    }
    let n = try await api.unseenCount()
    XCTAssertEqual(n, 107)
  }
  func testLikesUseLastUserAndPageNumber() async throws {
    let fixture: [UInt8] = [10, 7, 8, 77, 26, 3, 18, 1, 65, 16, 1, 24, 1]
    let api = DynamicGateway { method, data in
      XCTAssertEqual(method.path, "/bilibili.app.dynamic.v2.Dynamic/LikeList")
      let q = try PiliBilibiliAppDynamicV2_LikeListReq(serializedBytes: data.dropFirst(5))
      XCTAssertEqual(q.dynamicID, "123")
      XCTAssertEqual(q.uidOffset, q.page == 1 ? 0 : 77)
      var response = try PiliBilibiliAppDynamicV2_LikeListReply(serializedBytes: fixture)
      response.list[0].author.pendant.image = "https://example.invalid/frame"
      response.list[0].author.official.type = 1
      response.list[0].author.level = 6; response.list[0].author.isSeniorMember = 1
      response.list[0].author.sign = "签名"
      response.list[0].author.vip.status = 1
      response.list[0].decorateCard.cardURL = "https://example.invalid/card"
      response.list[0].decorateCard.fan.numberStr = "0004"
      return .init(
        status: 200, contentType: "application/grpc", headers: ["grpc-status": "0"],
        data: try WireFrame.encode(response.serializedData()))
    }
    let first = try await api.likes("123")
    XCTAssertEqual(first.rows.first?.name, "A")
    XCTAssertEqual(first.rows.first?.pendant, "https://example.invalid/frame")
    XCTAssertEqual(first.rows.first?.verify, 1)
    XCTAssertEqual(first.rows.first?.sign, "签名"); XCTAssertEqual(first.rows.first?.level, 6)
    XCTAssertEqual(first.rows.first?.senior, true)
    XCTAssertEqual(first.rows.first?.vipStatus, 1)
    XCTAssertEqual(first.rows.first?.cardURL, "https://example.invalid/card")
    XCTAssertEqual(first.rows.first?.fanNumber, "0004")
    XCTAssertEqual(first.next, "2:77")
    let second = try await api.likes("123", cursor: first.next)
    XCTAssertNil(second.next)
    let repost = DynamicGateway { method, data in
      let req = try PiliBilibiliAppDynamicV2_RepostListReq(serializedBytes: data.dropFirst(5))
      XCTAssertEqual(req.offset, "pg")
      XCTAssertEqual(method.path, "/bilibili.app.dynamic.v2.Dynamic/RepostList")
      XCTAssertEqual(req.repostType, .repostGeneral)
      return .init(
        status: 200, contentType: "application/grpc", headers: ["grpc-status": "0"],
        data: try WireFrame.encode(Data([18, 2, 112, 103, 24, 1, 32, 6])))
    }
    let end = try await repost.reposts("123", cursor: "pg")
    XCTAssertEqual(end.total, 6)
    XCTAssertNil(end.next)
  }
  func testRepostUsesOpusInlineResourcesBeforePlainDescription() async throws {
    let api = DynamicGateway { _, _ in
      var r = PiliBilibiliAppDynamicV2_RepostListRsp()
      var row = PiliBilibiliAppDynamicV2_DynamicItem()
      row.extend.dynIDStr = "292"
      var p = PiliBilibiliAppDynamicV2_TextParagraph()
      var vote = PiliBilibiliAppDynamicV2_TextNode()
      vote.link.linkTypeEnum = .vote; vote.link.bizID = "19"; vote.link.showText.words = "投票"
      var pic = PiliBilibiliAppDynamicV2_TextNode()
      pic.link.linkTypeEnum = .repostPicDynURL
      var img = PiliBilibiliAppDynamicV2_MdlDynDrawItem()
      img.src = "https://example.invalid/a.jpg"; img.isLivePhoto = true; img.liveVideoURL = "https://example.invalid/a.mov"
      pic.link.linkPics.items = [img]
      var e = PiliBilibiliAppDynamicV2_TextNode()
      e.emote.rawText.words = "[表情]"; e.emote.emoteURL = "https://example.invalid/e.png"
      var web = PiliBilibiliAppDynamicV2_TextNode()
      web.link.showText.words = "原文"; web.link.link = "https://example.invalid/source"
      p.nodes = [vote,pic,e,web]; row.extend.opusSummary.summary.text = p
      r.list = [row]
      return .init(status:200,contentType:"application/grpc",headers:["grpc-status":"0"],data:try WireFrame.encode(r.serializedData()))
    }
    let rows = try await api.reposts("120").rows
    let entry = try XCTUnwrap(rows.first)
    XCTAssertEqual(entry.id,"292"); XCTAssertEqual(entry.body.count,4)
    XCTAssertEqual(entry.body[0],.vote("投票",19))
    guard case let .pictures(pictures) = entry.body[1] else { return XCTFail("图片节点被扁平化") }
    XCTAssertEqual(pictures.first?.movie,"https://example.invalid/a.mov")
    XCTAssertEqual(entry.body[2], .emote("[表情]","https://example.invalid/e.png",0))
    XCTAssertEqual(entry.body[3], .link("原文","https://example.invalid/source"))
  }
  func testPublicSpaceAndActivity() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["PILI_PUBLIC_SMOKE"] == "1",
      "Opt-in read of a public creator, with no cookies or credentials")
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.timeoutIntervalForRequest = 15
    let session = URLSession(configuration: config)
    defer { session.finishTasksAndInvalidate() }
    let api = DynamicGateway { m, data in
      var request = URLRequest(url: URL(string: "https://app.bilibili.com" + m.path)!)
      request.httpMethod = "POST"
      request.httpBody = data
      request.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
      request.setValue("identity,gzip", forHTTPHeaderField: "grpc-accept-encoding")
      request.setValue("PiliNative/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
      let (data, response) = try await session.data(for: request)
      let h = try XCTUnwrap(response as? HTTPURLResponse)
      print(
        "Public read \(m.path.split(separator:"/").last ?? "RPC"): HTTP \(h.statusCode), gRPC \(h.value(forHTTPHeaderField:"grpc-status") ?? "missing"), bytes \(data.count)"
      )
      let headers = Dictionary(
        uniqueKeysWithValues: ["grpc-status", "grpc-message", "grpc-encoding"].compactMap { k in
          h.value(forHTTPHeaderField: k).map { (k, $0) }
        })
      return .init(
        status: h.statusCode, contentType: h.mimeType ?? "", headers: headers, data: data)
    }
    let first = try await api.space(2)
    print(
      "Public space: rows=\(first.rows.count), collections=\(first.collections.count), hasNext=\(first.next != nil)"
    )
    let item = try XCTUnwrap(first.rows.first)
    XCTAssertFalse(item.id.isEmpty)
    XCTAssertFalse(item.text.isEmpty && item.cover.isEmpty)
    if let next = first.next {
      let second = try await api.space(2, cursor: next)
      XCTAssertFalse(second.rows.isEmpty)
      XCTAssertNotEqual(item.id, second.rows.first?.id)
    }
    let likes = try await api.likes(item.id)
    let reposts = try await api.reposts(item.id)
    print(
      "Public creator records: opus=\(first.rows.count), collections=\(first.collections.count), like rows=\(likes.rows.count), repost rows=\(reposts.rows.count)"
    )
  }
}
