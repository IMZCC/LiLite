import Foundation

// Run independently of iOS with the production parser. Covers extended offsets,
// bounds checks and a media file whose SIDX is not the first box in the range.
@main struct SegmentIndexCheck {
  static func bytes(_ n: UInt64, _ width: Int) -> [UInt8] {
    (0..<width).reversed().map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }
  }
  static func main() throws {
    for version: UInt64 in [0, 1] {
      let width = version == 1 ? 8 : 4
      let offset: UInt64 = version == 1 ? 0x1_0000_0002 : 3
      var payload = bytes(version, 1) + [0, 0, 0] + bytes(1, 4) + bytes(1000, 4)
      payload += bytes(0, width) + bytes(offset, width) + bytes(0, 2) + bytes(2, 2)
      payload += bytes(200, 4) + bytes(4500, 4) + bytes(0, 4)
      payload += bytes(100, 4) + bytes(2600, 4) + bytes(0, 4)
      let box = bytes(UInt64(8 + payload.count), 4) + Array("sidx".utf8) + payload
      let data = Data(bytes(8, 4) + Array("free".utf8) + box)
      let first = Int64(data.count) + 512 + Int64(offset)
      let result = try SegmentIndex.parse(data, beginning: 512)
      precondition(
        result == [
          .init(bytes: .init(first, first + 199), seconds: 4.5),
          .init(bytes: .init(first + 200, first + 299), seconds: 2.6),
        ])
      precondition((try? SegmentIndex.parse(data.dropLast(), beginning: 512)) == nil)
    }
    precondition(ByteSpan("4-3") == nil && ByteSpan("-1-4") == nil)
    if CommandLine.arguments.count == 3, let start = Int64(CommandLine.arguments[2]) {
      let fragments = try SegmentIndex.parse(
        Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])), beginning: start)
      print(
        "Device stream:", fragments.count, "segments,", fragments.reduce(0) { $0 + $1.seconds },
        "seconds")
    }
    print("Segment index checks passed")
  }
}
