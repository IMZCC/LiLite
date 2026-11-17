/// A single-track fMP4 address space over an interleaved classic MP4. The headers and source
/// ranges are kept in memory; the compressed payload stays in the original file.
import Foundation

final class LocalMovieFragments: LocalTrackBytes, @unchecked Sendable {
  private struct Piece { let end: Int64, source: Int64, header: Int }
  private let original: any LocalTrackBytes, parts: [Piece], headers: [Data]
  var originalLength: Int64 { original.length }
  let length: Int64
  private static func u32(_ n: UInt32) -> Data {
    var n = n.bigEndian
    return withUnsafeBytes(of: &n) { Data($0) }
  }
  private static func box(_ name: String, _ data: Data) -> Data {
    u32(UInt32(data.count + 8)) + Data(name.utf8) + data
  }
  init(_ track: LocalMovieTable) throws {
    let box = Self.box
    let u32 = Self.u32
    original = track.source.playbackBacking
    var blocks: [Piece] = []
    var bytes: [Data] = []
    var end: Int64 = 0
    func head(_ value: Data) {
      end += Int64(value.count)
      blocks.append(.init(end: end, source: -1, header: bytes.count))
      bytes.append(value)
    }
    func span(_ start: Int64, _ size: UInt32) {
      if let last = blocks.last, last.source >= 0 {
        let begin = blocks.count > 1 ? blocks[blocks.count - 2].end : 0
        if last.source + last.end - begin == start {
          end += Int64(size)
          blocks[blocks.count - 1] = .init(end: end, source: last.source, header: -1)
          return
        }
      }
      end += Int64(size)
      blocks.append(.init(end: end, source: start, header: -1))
    }
    let zero = u32(0)
    let noEntries = zero + zero
    let stbl = box(
      "stbl",
      track.stsd + box("stts", noEntries) + box("stsc", noEntries) + box("stsz", noEntries + zero)
        + box("stco", noEntries))
    let minf = box("minf", track.minfHead + stbl)
    let trackBox = box(
      "trak", track.tkhd + track.edit + box("mdia", track.mdhd + track.hdlr + minf))
    let trex = box("trex", zero + u32(track.id) + u32(1) + zero + zero + zero)
    let ftyp = box("ftyp", Data("iso6".utf8) + zero + Data("iso6isommp41dash".utf8))
    head(ftyp + box("moov", track.mvhd + trackBox + box("mvex", trex)))
    var start = 0
    var seq: UInt32 = 1
    var clock: UInt64 = 0
    var time: UInt64 = 0
    var payload = 0
    let timescale = UInt64(track.scale)
    func flush(_ stop: Int) throws {
      let count = stop - start
      guard count > 0, count <= 65536, payload <= 44 * 1024 * 1024, seq <= 65536 else {
        throw LocalIndexIssue.invalid
      }
      let mfhd = box("mfhd", zero + u32(seq))
      let tfhd = box("tfhd", u32(0x020000) + u32(track.id))
      let tfdt = box(
        "tfdt", u32(0x0100_0000) + u32(UInt32(clock >> 32)) + u32(UInt32(truncatingIfNeeded: clock))
      )
      let tableSize = 16 * count
      // moof/traf/trun headers + trun version/flags, count, data_offset + mdat header.
      let offset = 8 + mfhd.count + 8 + tfhd.count + tfdt.count + 20 + tableSize + 8
      var trun = u32(0x0100_0f01) + u32(UInt32(count)) + u32(UInt32(offset))
      trun.reserveCapacity(12 + tableSize)
      func append(_ n: UInt32) {
        var n = n.bigEndian
        withUnsafeBytes(of: &n) { trun.append(contentsOf: $0) }
      }
      for s in track.samples[start..<stop] {
        append(s.duration)
        append(s.size)
        append(s.key ? 0x0200_0000 : 0x0101_0000)
        append(s.composition)
      }
      let moof = box("moof", mfhd + box("traf", tfhd + tfdt + box("trun", trun)))
      head(moof + u32(UInt32(payload + 8)) + Data("mdat".utf8))
      for s in track.samples[start..<stop] { span(s.position, s.size) }
      seq += 1
      clock += time
      time = 0
      payload = 0
      start = stop
    }
    for (i, s) in track.samples.enumerated() {
      if i & 4095 == 0 { try Task.checkCancellation() }
      if i > start && s.key && (time >= timescale * 2 || payload >= 4 * 1024 * 1024) {
        try flush(i)
      }
      payload += Int(s.size)
      time += UInt64(s.duration)
      guard payload <= 44 * 1024 * 1024, time <= 90 * timescale else {
        throw LocalIndexIssue.invalid
      }
    }
    try flush(track.samples.count)
    length = end
    headers = bytes
    parts = blocks
  }
  func data(_ start: Int64, _ count: Int) throws -> Data {
    guard count > 0, count <= 48 * 1024 * 1024, start >= 0, start <= length - Int64(count) else {
      throw LocalIndexIssue.invalid
    }
    var low = 0
    var high = parts.count
    while low < high {
      let m = (low + high) / 2
      if parts[m].end <= start { low = m + 1 } else { high = m }
    }
    var cursor = start
    var out = Data()
    out.reserveCapacity(count)
    while out.count < count {
      try Task.checkCancellation()
      let p = parts[low]
      let base = low > 0 ? parts[low - 1].end : 0
      let offset = cursor - base
      let n = min(Int(p.end - cursor), count - out.count)
      if p.source >= 0 {
        out.append(try original.data(p.source + offset, n))
      } else {
        out.append(headers[p.header][Int(offset)..<Int(offset) + n])
      }
      cursor += Int64(n)
      low += 1
    }
    return out
  }
  /// Batch neighbouring interleaved chunks into bounded HTTP ranges. Only the selected track's
  /// bytes are copied to the rendered fMP4, including when the request cuts through a sample.
  func online(
    _ start: Int64, _ count: Int,
    fetch: (Int64, Int) async throws -> Data
  ) async throws -> Data {
    guard count > 0, count <= 48 * 1024 * 1024, start >= 0, start <= length - Int64(count) else {
      throw LocalIndexIssue.invalid
    }
    var low = 0
    var high = parts.count
    var position = start
    while low < high {
      let mid = (low + high) / 2
      if parts[mid].end <= start { low = mid + 1 } else { high = mid }
    }
    var out = Data()
    out.reserveCapacity(count)
    var spans: [(Int64, Int)] = []
    var begin: Int64 = 0
    var last: Int64 = 0
    func drain() async throws {
      guard !spans.isEmpty else { return }
      let all = try await fetch(begin, Int(last - begin))
      guard all.count == last - begin else { throw LocalIndexIssue.invalid }
      for (base, length) in spans {
        let i = all.startIndex + Int(base - begin)
        out.append(all[i..<i + length])
      }
      spans.removeAll(keepingCapacity: true)
    }
    while position < start + Int64(count) {
      try Task.checkCancellation()
      let p = parts[low]
      let base = low > 0 ? parts[low - 1].end : 0
      let offset = position - base
      let take = Int(min(p.end, start + Int64(count)) - position)
      if p.source < 0 {
        try await drain()
        out.append(headers[p.header][Int(offset)..<Int(offset) + take])
      } else {
        var at = p.source + offset
        var remaining = take
        while remaining > 0 {
          if !spans.isEmpty
            && (at < last || at - last > 32 * 1024 || at - begin >= 512 * 1024
              || spans.count >= 4096)
          {
            try await drain()
          }
          if spans.isEmpty { begin = at }
          let n = min(remaining, 512 * 1024 - Int(at - begin))
          spans.append((at, n))
          last = at + Int64(n)
          at = last
          remaining -= n
        }
      }
      low += 1
      position += Int64(take)
    }
    try await drain()
    guard out.count == count else { throw LocalIndexIssue.invalid }
    return out
  }
  static func track(_ file:any LocalTrackBytes,audio:Bool)throws->LocalFragmentIndex{
    guard let selected=try LocalMovieTable.load(file,requiringVideo:!audio).first(where:{$0.video != audio}) else{throw LocalIndexIssue.invalid}
    return try LocalFragmentIndex(file:Self(selected),audio:audio)
  }
  static func open(_ file: any LocalTrackBytes) throws -> (LocalFragmentIndex, LocalFragmentIndex?)
  {
    let tracks = try LocalMovieTable.load(file)
    guard let v = tracks.first(where: \.video) else { throw LocalIndexIssue.invalid }
    return try (
      LocalFragmentIndex(file: Self(v), audio: false),
      tracks.first(where: { !$0.video }).map { try LocalFragmentIndex(file: Self($0), audio: true) }
    )
  }
}
