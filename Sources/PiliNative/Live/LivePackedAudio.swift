import Foundation

/// RFC 8216 packed audio carries a 33-bit MPEG clock in an ID3 PRIV frame. Do not pass tags
/// through as sound frames; do not synthesize a common timeline from unrelated playlist numbers.
struct LivePackedAudio {
  let demux: Int32, clock: Int64?, bytes: Data
  static func inspect(_ input: Data) throws -> Self {
    let b = [UInt8](input.prefix(128 * 1024 + 16))
    guard b.count >= 7 else { throw LivePlaylistError.malformed }
    if b[0] == 0x47 && (b.count < 376 || b[188] == 0x47) {
      return .init(demux: 2, clock: nil, bytes: input)
    }
    func number(_ at: Int, _ sync: Bool) throws -> Int {
      guard at >= 0, at + 4 <= b.count else { throw LivePlaylistError.malformed }
      var v = 0
      for x in b[at..<at + 4] {
        if sync && x >= 128 { throw LivePlaylistError.malformed }
        v = v * (sync ? 128 : 256) + Int(x)
      }
      return v
    }
    var offset = 0
    var stamp: Int64?
    let owner = Array("com.apple.streaming.transportStreamTimestamp".utf8)
    while offset + 10 <= b.count, Array(b[offset..<offset + 3]) == [73, 68, 51] {
      let version = b[offset + 3]
      let flags = b[offset + 5]
      guard version == 3 || version == 4, (flags & 0xe0) == 0 else {
        throw LivePlaylistError.malformed
      }
      let size = try number(offset + 6, true)
      let end = offset + 10 + size
      guard size <= 128 * 1024, end <= b.count else { throw LivePlaylistError.malformed }
      var at = offset + 10
      while at + 10 <= end, b[at] != 0 {
        let length = try number(at + 4, version == 4)
        let start = at + 10
        guard length > 0, length <= end - start else { throw LivePlaylistError.malformed }
        if Array(b[at..<at + 4]) == [80, 82, 73, 86], b[at + 8] == 0, b[at + 9] == 0,
          length == owner.count + 9, Array(b[start..<start + owner.count]) == owner,
          b[start + owner.count] == 0
        {
          var v: UInt64 = 0
          for n in b[start + owner.count + 1..<start + length] { v = v << 8 | UInt64(n) }
          guard v < (1 << 33), stamp == nil || stamp == Int64(v) else {
            throw LivePlaylistError.malformed
          }
          stamp = Int64(v)
        }
        at = start + length
      }
      offset = end + ((version == 4 && flags & 0x10 != 0) ? 10 : 0)
    }
    guard offset + 7 <= b.count else { throw LivePlaylistError.malformed }
    let d: Int32
    if b[offset] == 0xff && (b[offset + 1] & 0xf6) == 0xf0 {
      d = 3
    }  // ADTS AAC
    else if b[offset] == 0xff && (b[offset + 1] & 0xe0) == 0xe0 && (b[offset + 1] & 6) != 0 {
      d = 4
    } else if b[offset] == 0x0b && b[offset + 1] == 0x77 {
      let id = b[offset + 5] >> 3
      guard id <= 16 else { throw LivePlaylistError.malformed }
      d = id <= 10 ? 5 : 6
    } else {
      throw LivePlaylistError.separateAudio
    }
    return .init(
      demux: d, clock: stamp,
      bytes: offset == 0 ? input : input.subdata(in: input.startIndex + offset..<input.endIndex))
  }
}
