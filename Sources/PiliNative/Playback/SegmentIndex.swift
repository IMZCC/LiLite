import Foundation

struct ByteSpan: Equatable {
  let lower: Int64, upper: Int64
  init?(_ text: String) {
    let f = text.split(separator: "-", omittingEmptySubsequences: false)
    guard f.count == 2, let a = Int64(f[0]), let b = Int64(f[1]), a >= 0, b >= a, b < Int64.max
    else { return nil }
    lower = a
    upper = b
  }
  init(_ a: Int64, _ b: Int64) {
    lower = a
    upper = b
  }
  var count: Int64 { upper - lower + 1 }
}
struct IndexedSegment: Equatable { let bytes: ByteSpan, seconds: Double }
enum SegmentIndex {
  enum Invalid: Error { case malformed }
  static func parse(_ data: Data, beginning: Int64) throws -> [IndexedSegment] {
    try timeline(data, beginning: beginning).segments
  }
  static func timeline(_ data: Data, beginning: Int64) throws -> (start: Double, segments: [IndexedSegment]) {
    let b = [UInt8](data)
    var pos = 0
    func number(_ n: Int) throws -> UInt64 {
      guard pos + n <= b.count else { throw Invalid.malformed }
      var v: UInt64 = 0
      for _ in 0..<n {
        v = (v << 8) | UInt64(b[pos])
        pos += 1
      }
      return v
    }
    while pos + 8 <= b.count {
      let start = pos
      var length = try number(4)
      let kind = try number(4)
      if length == 1 { length = try number(8) }
      if length == 0 { length = UInt64(b.count - start) }
      guard length <= b.count - start, Int(length) >= pos - start else { throw Invalid.malformed }
      let end = start + Int(length)
      guard kind == 0x7369_6478 else {
        pos = end
        continue
      }
      let version = try number(1)
      guard version <= 1 else { throw Invalid.malformed }
      _ = try number(3)
      _ = try number(4)
      let scale = try number(4)
      guard scale > 0 else { throw Invalid.malformed }
      let width = version == 0 ? 4 : 8
      let earliest = try number(width)
      let offset = try number(width)
      guard beginning >= 0, beginning < Int64.max - Int64(end),
        offset <= UInt64(Int64.max - beginning - Int64(end))
      else { throw Invalid.malformed }
      var cursor = beginning + Int64(end) + Int64(offset)
      _ = try number(2)
      let count = Int(try number(2))
      guard count > 0, pos + 12 * count <= end else { throw Invalid.malformed }
      var result: [IndexedSegment] = []
      for _ in 0..<count {
        let size = try number(4)
        let ticks = try number(4)
        _ = try number(4)
        guard size > 0, size < 0x8000_0000, ticks > 0, cursor <= Int64.max - Int64(size) else {
          throw Invalid.malformed
        }
        result.append(
          .init(
            bytes: ByteSpan(cursor, cursor + Int64(size) - 1),
            seconds: Double(ticks) / Double(scale)))
        cursor += Int64(size)
      }
      return (Double(earliest)/Double(scale), result)
    }
    throw Invalid.malformed
  }
}
