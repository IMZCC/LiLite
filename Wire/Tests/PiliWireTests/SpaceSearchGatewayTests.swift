import Foundation
import SwiftProtobuf
import XCTest
@testable import PiliWire

final class SpaceSearchGatewayTests: XCTestCase {
  func testTargetPageAndResourceKinds() async throws {
    let account: Int64 = 1 << 55
    let result = try await SpaceSearchGateway.page(mid: account, term: "压轴", number: 2) { frame in
      let request = try PiliBilibiliAppInterfacesV1_SearchArchiveReq(serializedBytes: frame.dropFirst(5))
      XCTAssertEqual(request.keyword, "压轴")
      XCTAssertEqual(request.mid, account)
      XCTAssertEqual(request.pn, 2)
      XCTAssertEqual(request.ps, 20)
      XCTAssertFalse(request.hasPlayerArgs)
      var regular = PiliBilibiliAppInterfacesV1_Arc()
      regular.archive.aid = 44; regular.archive.firstCid = 99; regular.archive.title = "压轴"; regular.archive.stat.view = 7
      var course = regular; course.isPugv = true; course.uri = "https://www.bilibili.com/cheese/play/ep303"
      var season = regular; season.archive.redirectURL = "https://www.bilibili.com/bangumi/play/ep101"
      var response = PiliBilibiliAppInterfacesV1_SearchArchiveReply()
      response.archives = [regular, course, season]; response.total = 43
      return .init(status:200,contentType:"application/grpc",headers:["grpc-status":"0"],data:try WireFrame.encode(response.serializedData()))
    }
    XCTAssertEqual(result.total,43)
    XCTAssertEqual(result.archives[0].archive.firstCid,99)
    XCTAssertTrue(result.archives[1].isPugv)
    XCTAssertEqual(result.archives[2].archive.redirectURL,"https://www.bilibili.com/bangumi/play/ep101")
    do {
      _ = try await SpaceSearchGateway.page(mid: 1, term: "拒绝", number: 1) { _ in
        .init(status:200,contentType:"application/grpc",headers:["grpc-status":"7"],data:Data())
      }
      XCTFail("denial accepted")
    } catch { XCTAssertTrue(error is WireError) }
  }
}
