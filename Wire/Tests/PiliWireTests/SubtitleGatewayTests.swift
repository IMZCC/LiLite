import Foundation
import XCTest

@testable import PiliWire

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class SubtitleGatewayTests: XCTestCase {
  func testPublicCatalog() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["PILI_SUBTITLE_SMOKE"] == "1")
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.httpCookieStorage = nil
    let session = URLSession(configuration: config)
    defer { session.finishTasksAndInvalidate() }
    for (aid, cid) in [(Int64(170001), Int64(279786)), (455_017_605, 168_409_646)] {
      let rows = try await SubtitleGateway.tracks(aid: aid, cid: cid) { bytes in
        var req = URLRequest(
          url: URL(string: "https://app.bilibili.com" + SubtitleGateway.path)!, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.httpBody = bytes
        req.httpShouldHandleCookies = false
        req.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
        req.setValue("identity,gzip", forHTTPHeaderField: "grpc-accept-encoding")
        req.setValue("PiliNative/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        let headers = Dictionary(
          uniqueKeysWithValues: ["grpc-status", "grpc-message", "grpc-encoding"].compactMap { key in
            http.value(forHTTPHeaderField: key).map { (key, $0) }
          })
        print("Guest subtitle catalog: HTTP \(http.statusCode), bytes \(data.count)")
        return .init(
          status: http.statusCode, contentType: http.mimeType ?? "", headers: headers, data: data)
      }
      print("Guest subtitle catalog av\(aid) / \(cid): \(rows.count) tracks")
    }
  }
  func testGuestRequestsExactPartAndPreservesAIAndTrackID() async throws {
    let rows = try await SubtitleGateway.tracks(aid: 170001, cid: 279786) { data in
      let q = try PiliBilibiliCommunityServiceDmV1_DmViewReq(serializedBytes: data.dropFirst(5))
      XCTAssertEqual(q.pid, 170001)
      XCTAssertEqual(q.oid, 279786)
      XCTAssertEqual(q.type, 1)
      var r = PiliBilibiliCommunityServiceDmV1_DmViewReply()
      var t = PiliBilibiliCommunityServiceDmV1_SubtitleItem()
      t.id = 123
      t.lan = "ai-zh"
      t.lanDoc = "中文"
      t.subtitleURL = "//example.org/sub.json"
      t.type = .ai
      r.subtitle.subtitles = [t]
      return .init(
        status: 200, contentType: "application/grpc", headers: ["grpc-status": "0"],
        data: try WireFrame.encode(r.serializedData()))
    }
    XCTAssertEqual(rows.map(\.id), ["123"])
    XCTAssertEqual(rows.first?.ai, true)
    XCTAssertEqual(rows.first?.url, "//example.org/sub.json")
  }
}
