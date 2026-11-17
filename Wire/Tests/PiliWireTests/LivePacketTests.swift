import Foundation
import XCTest

@testable import PiliWire

final class LivePacketTests: XCTestCase {
  // Python struct.pack(">IHHII", ...) combined three packets, then libbrotlienc / zlib compressed them independently.
  let z =
    "AAAAVAAQAAIAAAAFAAAAAXicY2BgkGIQYGBkYGDgAGLGaqXk/JRUJSuDWiBPBCrDDJJhYGAB0cpAMRBgharOTVGyUnJx9PMNjfcNdleqBQAd0gmI"
  let br =
    "AAAAXAAQAAMAAAAFAAAAARdQAAAEim2eqGA0mIxvKGabIJi0jOWV1YU0dMp5oBS3NS/yHK6HjbFszEA6gUzEACE1v9yo1QMkC0vkdgqxxP7xfq+aRt/rftY1dQA="
  func testMultiplexedCompressedRoomFrames() throws {
    let event = Data(#"{"cmd":"DANMU_MSG"}"#.utf8)
    for sample in [z, br] {
      let packet = try XCTUnwrap(Data(base64Encoded: sample))
      XCTAssertEqual(
        try LivePackets.decode(packet), [.authenticated, .popularity(1027), .event(event)])
      XCTAssertThrowsError(try LivePackets.decode(Data(packet.dropLast())))
      var trailing = packet
      trailing.append(0)
      XCTAssertThrowsError(try LivePackets.decode(trailing))
    }
    let beat = try LivePackets.encode(2, data: Data(), sequence: 7)
    XCTAssertEqual(Array(beat), [0, 0, 0, 16, 0, 16, 0, 1, 0, 0, 0, 2, 0, 0, 0, 7])
    XCTAssertThrowsError(
      try LivePackets.decode(LivePackets.encode(8, data: Data(#"{"code":-101}"#.utf8))))
    XCTAssertThrowsError(try LivePackets.decode(LivePackets.encode(8, data: Data("{}".utf8))))
  }
}
