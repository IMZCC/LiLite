import Foundation
import SwiftProtobuf
import XCTest

@testable import PiliWire

final class ServiceReceiptErrorTests: XCTestCase {
  private func failure(
    _ reply: GatewayReply, _ code: Int, _ message: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    do {
      _ = try WireFrame.decode(reply)
      XCTFail("denial was accepted", file: file, line: line)
    } catch WireError.remote(let actual, let text) {
      XCTAssertEqual(actual, code, file: file, line: line)
      XCTAssertEqual(text, message, file: file, line: line)
    } catch { XCTFail("unexpected failure: \(error)", file: file, line: line) }
  }
  func testBusinessReceiptAndUntrustedBodies() throws {
    var denied = PiliBilibiliRpc_Status()
    denied.code = -352
    denied.message = "需要验证"
    var second = PiliBilibiliRpc_Status()
    second.message = "请在官方页面继续"
    func any(_ value: PiliBilibiliRpc_Status) throws -> Google_Protobuf_Any {
      var a = Google_Protobuf_Any()
      a.typeURL = "type.googleapis.com/bilibili.rpc.Status"
      a.value = try value.serializedData()
      return a
    }
    var outer = PiliBilibiliRpc_Status()
    outer.code = 2
    outer.message = "UNKNOWN"
    outer.details = try [any(denied), any(second)]
    let unpadded = try outer.serializedData().base64EncodedString().replacingOccurrences(
      of: "=", with: "")
    failure(
      .init(
        status: 200, contentType: "application/grpc",
        headers: ["grpc-status": "2", "Grpc-Status-Details-Bin": unpadded], data: Data()), -352,
      "需要验证\n请在官方页面继续")
    var unrelated = try any(denied)
    unrelated.typeURL = "type.googleapis.com/example.NotAStatus"
    outer.details = [unrelated]
    outer.message = "服务拒绝"
    let wrongType = try outer.serializedData().base64EncodedString()
    failure(
      .init(
        status: 200, contentType: "application/grpc",
        headers: ["grpc-status": "7", "grpc-status-details-bin": wrongType], data: Data()), 7,
      "服务拒绝")
    failure(
      .init(
        status: 200, contentType: "application/grpc",
        headers: [
          "grpc-status": "16", "grpc-status-details-bin": "%bad",
          "grpc-message": "%E6%8B%92%E7%BB%9D",
        ], data: Data()), 16, "拒绝")
    failure(
      .init(
        status: 403, contentType: "application/json; charset=utf-8", headers: [:],
        data: Data(#"{"code":-101,"message":"请登录"}"#.utf8)), -101, "请登录")
    XCTAssertThrowsError(
      try WireFrame.decode(
        .init(
          status: 200, contentType: "application/json",
          headers: [:], data: Data(#"{"code":0,"message":"OK"}"#.utf8))))
    let oversized = String(repeating: "A", count: 17000)
    failure(
      .init(
        status: 200, contentType: "application/grpc",
        headers: ["grpc-status": "7", "grpc-message": "拒绝", "grpc-status-details-bin": oversized],
        data: Data()), 7, "拒绝")
  }
}
