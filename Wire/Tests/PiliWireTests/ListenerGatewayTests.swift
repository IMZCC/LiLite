import Foundation
import SwiftProtobuf
import XCTest

@testable import PiliWire

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class ListenerGatewayTests: XCTestCase {
  private func envelope<M: SwiftProtobuf.Message>(_ m: M) throws -> GatewayReply {
    .init(
      status: 200, contentType: "application/grpc", headers: ["grpc-status": "0"],
      data: try WireFrame.encode(m.serializedData()))
  }
  func testAnchorThenOpaqueCursorWithoutAnchor() async throws {
    let t = ListenerGateway.item(oid: 71234, sub: 99876, type: 1)
    var list = PiliBilibiliAppListenerV1_PlaylistResp()
    list.total = 40
    list.paginationReply.prev = "left/A"
    list.paginationReply.next = "right/+?"
    var row = ListenerGateway.Row()
    row.item = t
    row.arc.title = "sample"
    list.list = [row]
    let reply = try envelope(list)
    for cursor: String? in [nil, "left/A", "right/+?"] {
      let gw = ListenerGateway { m, d in
        XCTAssertTrue(m.reads)
        XCTAssertEqual(m.path, "/bilibili.app.listener.v1.Listener/Playlist")
        let q = try PiliBilibiliAppListenerV1_PlaylistReq(serializedBytes: d.dropFirst(5))
        XCTAssertEqual(q.id, 501)
        XCTAssertEqual(q.extraID, 2)
        XCTAssertEqual(q.pagination.pageSize, 20)
        XCTAssertEqual(q.sortOpt.order, .orderReverse)
        XCTAssertEqual(q.playerArgs.qn, 80)
        XCTAssertEqual(q.playerArgs.fnval, 4048)
        XCTAssertEqual(q.playerArgs.forceHost, 2)
        if let cursor {
          XCTAssertEqual(q.pagination.next, cursor)
          XCTAssertEqual(q.anchor.oid, 0)
          XCTAssertEqual(q.from, .default)
        } else {
          XCTAssertEqual(q.from, .userFavourite)
          XCTAssertEqual(q.anchor, t)
        }
        return reply
      }
      let page = try await gw.playlist(
        id: 501, source: 4, extra: 2, anchor: t, order: 2, cursor: cursor)
      XCTAssertEqual(page.list.first?.item.subID, [99876])
      XCTAssertEqual(page.paginationReply.next, "right/+?")
    }
  }
  func testExactPartPreferredToOtherAudioAndDeniedReceipt() async throws {
    let t = ListenerGateway.item(oid: 63, sub: 82, type: 1)
    var primary = ListenerGateway.Media()
    primary.playDash.duration = 3
    primary.qn = 30280
    var wrong = ListenerGateway.Media()
    wrong.qn = 42
    wrong.playURL.durl = []
    var payload = PiliBilibiliAppListenerV1_PlayURLResp()
    payload.playerInfo = [12: wrong, 82: primary]
    let ok = try envelope(payload)
    let gw = ListenerGateway { method, data in
      XCTAssertEqual(method, .playURL)
      XCTAssertTrue(method.reads)
      let r = try PiliBilibiliAppListenerV1_PlayURLReq(serializedBytes: data.dropFirst(5))
      XCTAssertEqual(r.item, t)
      XCTAssertEqual(r.playerArgs.voiceBalance, 1)
      return ok
    }
    let got = try await gw.media(t)
    XCTAssertEqual(got.qn, 30280)
    var denied = ListenerGateway.Media()
    denied.code = -10403
    denied.message = "not available"
    payload.playerInfo = [82: denied]
    let fail = try envelope(payload)
    do {
      _ = try await ListenerGateway { _, _ in fail }.media(t)
      XCTFail("must retain service restriction")
    } catch WireError.remote(let n, _) { XCTAssertEqual(n, -10403) }
  }
  func testUserMutationsAreSeparatedAndNeverReadCalls() async throws {
    let item = ListenerGateway.item(oid: 14, sub: 14, type: 3)
    var c = PiliBilibiliAppListenerV1_CoinAddResp()
    c.message = "accepted"
    var triple = PiliBilibiliAppListenerV1_TripleLikeResp()
    triple.thumbOk = true
    triple.favOk = true
    let coinData = try envelope(c)
    let tripleData = try envelope(triple)
    let likeData = try envelope(PiliBilibiliAppListenerV1_ThumbUpResp())
    let gw = ListenerGateway { method, frame in
      XCTAssertFalse(method.reads)
      switch method {
      case .coin:
        let q = try PiliBilibiliAppListenerV1_CoinAddReq(serializedBytes: frame.dropFirst(5))
        XCTAssertEqual(q.item, item)
        XCTAssertEqual(q.num, 1)
        XCTAssertTrue(q.thumbUp)
        return coinData
      case .triple:
        let q = try PiliBilibiliAppListenerV1_TripleLikeReq(serializedBytes: frame.dropFirst(5))
        XCTAssertEqual(q.item, item)
        return tripleData
      case .thumb:
        let q = try PiliBilibiliAppListenerV1_ThumbUpReq(serializedBytes: frame.dropFirst(5))
        XCTAssertEqual(q.item, item)
        XCTAssertEqual(q.action, .cancelLike)
        return likeData
      default:
        XCTFail("unexpected call")
        return likeData
      }
    }
    let coin = try await gw.update(.coin(1, true), item: item)
    XCTAssertTrue(coin.coin && coin.like)
    let partial = try await gw.update(.triple, item: item)
    XCTAssertTrue(partial.fav && partial.like)
    XCTAssertFalse(partial.coin)
    let cancelled = try await gw.update(.like(false), item: item)
    XCTAssertFalse(cancelled.like)
  }
  func testPublicListenerReadback() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["PILI_LISTENER_PUBLIC"] == "1",
      "Optional anonymous network test")
    let gw = ListenerGateway { method, body in
      guard method.reads else { throw URLError(.unsupportedURL) }
      let u = URL(string: "https://app.bilibili.com" + method.path)!
      var r = URLRequest(url: u, timeoutInterval: 12)
      r.httpMethod = "POST"
      r.httpBody = body
      r.httpShouldHandleCookies = false
      r.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
      r.setValue("identity,gzip", forHTTPHeaderField: "grpc-accept-encoding")
      let headers = try ClientMetadata.headers(device: "", token: nil, build: 1, version: "1.0")
      for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
      let cfg = URLSessionConfiguration.ephemeral
      cfg.httpCookieStorage = nil
      cfg.urlCredentialStorage = nil
      cfg.httpShouldSetCookies = false
      let session = URLSession(configuration: cfg)
      defer { session.invalidateAndCancel() }
      let (data, res) = try await session.data(for: r)
      let h = try XCTUnwrap(res as? HTTPURLResponse)
      let fields = Dictionary(
        uniqueKeysWithValues: ["grpc-status", "grpc-message", "grpc-encoding"].compactMap { k in
          h.value(forHTTPHeaderField: k).map { (k, $0) }
        })
      return .init(status: h.statusCode, contentType: h.mimeType ?? "", headers: fields, data: data)
    }
    let aid: Int64 = 883_362_563
    let cid: Int64 = 196_018_899
    let t = ListenerGateway.item(oid: aid, sub: cid, type: 1)
    do {
      let first = try await gw.playlist(
        id: aid, source: 5, extra: nil, anchor: t, order: 1, cursor: nil)
      XCTAssertTrue(first.list.contains { $0.item.oid == aid })
      print("Anonymous listener playlist rows:", first.list.count)
    } catch WireError.remote(let code, let msg) where code == 2 && msg == "-101" {
      print("Anonymous Listener/Playlist requires login (2/-101); authenticated results not tested")
    }
    do {
      let media = try await gw.media(t)
      XCTAssertNotNil(media.info)
      print(
        "Anonymous listener audio variants:", media.playDash.audio.count, "files:",
        media.playURL.durl.count)
    } catch WireError.remote(let code, let msg) where code == 2 && msg == "-101" {
      print("Anonymous Listener/PlayURL requires login (2/-101); authenticated results not tested")
    }
  }
}
