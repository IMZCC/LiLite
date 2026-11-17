/// MP4 metadata only. All media reads are from the already-authorized file descriptor; file names,
/// URL data references and media paths in metadata never become inputs to a separate file open.
import Foundation

protocol LocalTrackBytes: Sendable {
  var length: Int64 { get }
  var playbackBacking: any LocalTrackBytes { get }
  func data(_ start: Int64, _ count: Int) throws -> Data
}
extension LocalTrackBytes {
  var playbackBacking: any LocalTrackBytes { self }
}
final class LocalMediaFile: LocalTrackBytes, @unchecked Sendable {
  let length: Int64
  private let handle: FileHandle, lock = NSLock()
  init(_ url: URL) throws {
    guard url.isFileURL else { throw URLError(.unsupportedURL) }
    let r = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard r.isRegularFile == true, r.isSymbolicLink != true else {
      throw URLError(.noPermissionsToReadFile)
    }
    let h = try FileHandle(forReadingFrom: url)
    let n = try h.seekToEnd()
    guard n > 0, n <= 512 * 1024 * 1024 * 1024 else {
      try? h.close()
      throw URLError(.dataLengthExceedsMaximum)
    }
    self.handle = h
    self.length = Int64(n)
  }
  func data(_ start: Int64, _ count: Int) throws -> Data {
    guard count > 0, count <= 48 * 1024 * 1024, start >= 0, start <= length - Int64(count) else {
      throw URLError(.badServerResponse)
    }
    return try lock.withLock {
      try handle.seek(toOffset: UInt64(start))
      var bytes = Data()
      bytes.reserveCapacity(count)
      while bytes.count < count {
        try Task.checkCancellation()
        guard let d = try handle.read(upToCount: min(512 * 1024, count - bytes.count)), !d.isEmpty
        else { throw URLError(.cannotDecodeContentData) }
        bytes.append(d)
      }
      return bytes
    }
  }
  deinit { try? handle.close() }
}
enum LocalIndexIssue: LocalizedError {
  case notFragmented, invalid, encrypted, external
  var errorDescription: String? {
    switch self {
    case .notFragmented, .invalid: return "无法读取视频分段信息"
    case .encrypted: return "视频使用了受保护的轨道"
    case .external: return "视频包含外部媒体引用"
    }
  }
}
struct LocalAtom {
  let start: Int64, end: Int64, head: Int64, kind: String
  var body: Int64 { start + head }
  var size: Int64 { end - start }
  static func uint(_ data: Data, _ at: Int, _ n: Int) throws -> UInt64 {
    guard n > 0, n <= 8, at >= 0, at <= data.count - n else { throw LocalIndexIssue.invalid }
    var result: UInt64 = 0
    for i in at..<at + n { result = result << 8 | UInt64(data[data.startIndex + i]) }
    return result
  }
  static func scan(_ lower: Int64, _ upper: Int64, read: (Int64, Int) throws -> Data) throws
    -> [LocalAtom]
  {
    var out: [LocalAtom] = []
    var p = lower
    while p < upper {
      try Task.checkCancellation()
      guard p >= 0, upper - p >= 8, out.count < 131072 else { throw LocalIndexIssue.invalid }
      let h = try read(p, 8)
      var size = try uint(h, 0, 4)
      var head: Int64 = 8
      if size == 1 {
        guard upper - p >= 16 else { throw LocalIndexIssue.invalid }
        size = try uint(read(p + 8, 8), 0, 8)
        head = 16
      }
      if size == 0 { size = UInt64(upper - p) }
      guard size >= UInt64(head), size <= UInt64(upper - p) else { throw LocalIndexIssue.invalid }
      let tag = String(decoding: h[h.startIndex + 4..<h.startIndex + 8], as: UTF8.self)
      out.append(.init(start: p, end: p + Int64(size), head: head, kind: tag))
      p += Int64(size)
    }
    return out
  }
}
struct LocalFragmentIndex {
  let file: any LocalTrackBytes, initial: ByteSpan, fragments: [IndexedSegment], codec: String
  let width: Int?, height: Int?, bitrate: Int
  private struct MovieTrack {
    var id: Int = 0, scale: UInt64 = 0, defaultDuration: UInt64 = 0
    var codec = "", width: Int?, height: Int?
  }
  init(url: URL, audio: Bool) throws {
    try self.init(file: LocalMediaFile(url), audio: audio)
  }
  init(file: any LocalTrackBytes, audio: Bool) throws {
    self.file = file
    let top = try LocalAtom.scan(0, file.length, read: file.data)
    guard let moov = top.first(where: { $0.kind == "moov" }),
      let first = top.first(where: { $0.kind == "moof" })
    else { throw LocalIndexIssue.notFragmented }
    guard moov.end <= first.start, moov.end <= 4 * 1024 * 1024 else {
      throw LocalIndexIssue.invalid
    }
    initial = ByteSpan(0, moov.end - 1)
    let prefix = try file.data(0, Int(moov.end))
    func sub(_ p: Int64, _ n: Int) throws -> Data {
      guard p >= 0, p <= Int64(prefix.count - n) else { throw LocalIndexIssue.invalid }
      return prefix.subdata(in: Int(p)..<Int(p) + n)
    }
    func children(_ box: LocalAtom, _ skip: Int64 = 0) throws -> [LocalAtom] {
      try LocalAtom.scan(box.body + skip, box.end, read: sub)
    }
    func child(_ box: LocalAtom, _ name: String) throws -> LocalAtom {
      guard let value = try children(box).first(where: { $0.kind == name }) else {
        throw LocalIndexIssue.invalid
      }
      return value
    }
    func field(_ box: LocalAtom, _ at: Int, _ n: Int) throws -> UInt64 {
      guard box.body + Int64(at + n) <= box.end else { throw LocalIndexIssue.invalid }
      return try LocalAtom.uint(prefix, Int(box.body) + at, n)
    }
    var found: [MovieTrack] = []
    for trak in try children(moov).filter({ $0.kind == "trak" }) {
      let mdia = try child(trak, "mdia")
      let hdlr = try child(mdia, "hdlr")
      let handler = try field(hdlr, 8, 4)
      guard handler == (audio ? 0x736f_756e : 0x7669_6465) else { continue }
      var t = MovieTrack()
      let tk = try child(trak, "tkhd")
      let md = try child(mdia, "mdhd")
      t.id = Int(try field(tk, try field(tk, 0, 1) == 1 ? 20 : 12, 4))
      t.scale = try field(md, try field(md, 0, 1) == 1 ? 20 : 12, 4)
      let minf = try child(mdia, "minf")
      let stbl = try child(minf, "stbl")
      let dref = try child(child(minf, "dinf"), "dref")
      let refs = try children(dref, 8)
      guard refs.count == 1, refs[0].kind == "url ", try field(refs[0], 0, 4) == 1,
        refs[0].size == refs[0].head + 4
      else { throw LocalIndexIssue.external }
      let desc = try child(stbl, "stsd")
      let entries = try children(desc, 8)
      guard entries.count == 1, let entry = entries.first else { throw LocalIndexIssue.invalid }
      guard try field(entry, 6, 2) == 1 else { throw LocalIndexIssue.external }
      if ["encv", "enca", "drmi", "drms"].contains(entry.kind) { throw LocalIndexIssue.encrypted }
      if audio {
        let version = try field(entry, 8, 2)
        let skip: Int64 = version == 0 ? 28 : version == 1 ? 44 : version == 2 ? 64 : -1
        guard skip >= 0 else { throw LocalIndexIssue.invalid }
        let boxes = try children(entry, skip)
        guard !boxes.contains(where: { $0.kind == "sinf" }) else { throw LocalIndexIssue.encrypted }
        switch entry.kind.lowercased() {
        case "mp4a":
          guard let es = boxes.first(where: { $0.kind == "esds" }) else {
            throw LocalIndexIssue.invalid
          }
          t.codec = try Self.audioCodec(sub(es.body + 4, Int(es.size - es.head - 4)))
        case "flac": t.codec = "fLaC"
        case "opus": t.codec = "opus"
        case "alac", "ac-3", "ec-3": t.codec = entry.kind.lowercased()
        default: throw LocalIndexIssue.invalid
        }
      } else {
        t.width = Int(try field(entry, 24, 2))
        t.height = Int(try field(entry, 26, 2))
        let boxes = try children(entry, 78)
        guard !boxes.contains(where: { $0.kind == "sinf" }) else { throw LocalIndexIssue.encrypted }
        switch entry.kind {
        case "avc1", "avc3":
          guard let cfg = boxes.first(where: { $0.kind == "avcC" }) else {
            throw LocalIndexIssue.invalid
          }
          t.codec = entry.kind + "." + String(format: "%06X", Int(try field(cfg, 1, 3)))
        case "dvh1", "dvhe":
          if let dv = boxes.first(where: { $0.kind == "dvcC" || $0.kind == "dvvC" }) {
            let raw = try field(dv, 2, 2)
            t.codec =
              entry.kind + "." + String(format: "%02d.%02d", Int(raw >> 9), Int((raw >> 3) & 63))
          } else {
            t.codec = entry.kind
          }
        case "hvc1", "hev1":
          guard let cfg = boxes.first(where: { $0.kind == "hvcC" }) else {
            throw LocalIndexIssue.invalid
          }
          let head = try field(cfg, 1, 1)
          let level = try field(cfg, 12, 1)
          var raw = try field(cfg, 2, 4)
          var compat: UInt32 = 0
          for _ in 0..<32 {
            compat = compat << 1 | UInt32(raw & 1)
            raw >>= 1
          }
          var constraint = Array(try sub(cfg.body + 6, 6))
          while constraint.last == 0 { constraint.removeLast() }
          t.codec =
            entry.kind + "." + ["", "A", "B", "C"][Int(head >> 6)] + String(head & 31) + "."
            + String(compat, radix: 16, uppercase: true) + "." + (head & 32 == 0 ? "L" : "H")
            + String(level) + constraint.map { String(format: ".%02X", $0) }.joined()
        case "av01":
          guard let cfg = boxes.first(where: { $0.kind == "av1C" }), cfg.size - cfg.head >= 4 else {
            // Some fragmented AV1 tracks carry the sequence header in-band rather than in av1C.
            t.codec = entry.kind
            break
          }
          let b = try field(cfg, 1, 1)
          let c = try field(cfg, 2, 1)
          t.codec = String(
            format: "av01.%d.%02d%@.%02d", Int(b >> 5), Int(b & 31), c & 128 == 0 ? "M" : "H",
            c & 64 == 0 ? 8 : c & 32 == 0 ? 10 : 12)
        case "vp09":
          guard let cfg = boxes.first(where: { $0.kind == "vpcC" }) else {
            throw LocalIndexIssue.invalid
          }
          t.codec = String(
            format: "vp09.%02d.%02d.%02d", Int(try field(cfg, 4, 1)), Int(try field(cfg, 5, 1)),
            Int(try field(cfg, 6, 1) >> 4))
        default: throw LocalIndexIssue.invalid
        }
      }
      guard t.id > 0, t.scale > 0 else { throw LocalIndexIssue.invalid }
      if let mvex = try children(moov).first(where: { $0.kind == "mvex" }) {
        for trex in try children(mvex).filter({ $0.kind == "trex" })
        where try field(trex, 4, 4) == t.id {
          t.defaultDuration = try field(trex, 12, 4)
        }
      }
      found.append(t)
    }
    guard found.count == 1, let track = found.first else { throw LocalIndexIssue.invalid }
    codec = track.codec
    width = track.width
    height = track.height
    let moofs = top.enumerated().filter { $0.element.kind == "moof" }
    var indexed: [IndexedSegment] = []
    for index in top where index.kind == "sidx" && index.size <= 1024 * 1024 {
      let data = try file.data(index.start, Int(index.size))
      if let set = try? SegmentIndex.parse(data, beginning: index.start) {
        indexed.append(contentsOf: set)
      }
      if indexed.count > 131072 { throw LocalIndexIssue.invalid }
    }
    indexed.sort { $0.bytes.lower < $1.bytes.lower }
    var next = 0
    var previous: Int64 = -1
    var valid = !indexed.isEmpty
    for s in indexed {
      guard s.bytes.lower > previous, s.bytes.upper < file.length, s.seconds.isFinite, s.seconds > 0
      else {
        valid = false
        break
      }
      let old = next
      while next < moofs.count && moofs[next].element.start >= s.bytes.lower
        && moofs[next].element.start <= s.bytes.upper
      { next += 1 }
      if old == next {
        valid = false
        break
      }
      previous = s.bytes.upper
    }
    if valid && next == moofs.count {
      fragments = indexed
    } else {
      var built: [IndexedSegment] = []
      for (i, moof) in moofs {
        guard moof.size <= 4 * 1024 * 1024 else { throw LocalIndexIssue.invalid }
        let m = try file.data(moof.start, Int(moof.size))
        let ticks = try Self.ticks(m, track: track)
        var j = i + 1
        var end: Int64?
        while j < top.count && top[j].kind != "moof" {
          if top[j].kind == "mdat" { end = top[j].end }
          j += 1
        }
        guard let end, ticks > 0 else { throw LocalIndexIssue.invalid }
        built.append(
          .init(bytes: ByteSpan(moof.start, end - 1), seconds: Double(ticks) / Double(track.scale)))
      }
      fragments = built
    }
    let duration = fragments.reduce(0.0) { $0 + $1.seconds }
    guard duration > 0, duration.isFinite else { throw LocalIndexIssue.invalid }
    bitrate = Int(min(500_000_000, max(1, Double(file.length) * 8 / duration)))
  }
  private static func audioCodec(_ d: Data) throws -> String {
    func desc(_ p: inout Int, _ expect: UInt8) throws -> Range<Int> {
      guard p < d.count, d[p] == expect else { throw LocalIndexIssue.invalid }
      p += 1
      var n = 0
      for _ in 0..<4 {
        guard p < d.count else { throw LocalIndexIssue.invalid }
        let v = d[p]
        p += 1
        n = n * 128 + Int(v & 127)
        if v & 128 == 0 {
          guard n <= d.count - p else { throw LocalIndexIssue.invalid }
          return p..<p + n
        }
      }
      throw LocalIndexIssue.invalid
    }
    var p = 0
    let es = try desc(&p, 3)
    guard es.count >= 3 else { throw LocalIndexIssue.invalid }
    let fl = d[p + 2]
    p += 3
    if fl & 128 != 0 { p += 2 }
    if fl & 64 != 0 {
      guard p < es.upperBound else { throw LocalIndexIssue.invalid }
      p += 1 + Int(d[p])
    }
    if fl & 32 != 0 { p += 2 }
    let cfg = try desc(&p, 4)
    guard cfg.count >= 13, cfg.upperBound <= es.upperBound else { throw LocalIndexIssue.invalid }
    let object = d[p]
    p += 13
    if object == 0x69 || object == 0x6b { return String(format: "mp4a.%02X", object) }
    let a = try desc(&p, 5)
    guard object == 0x40, a.count >= 2, a.upperBound <= cfg.upperBound else {
      throw LocalIndexIssue.invalid
    }
    let t = Int(d[p] >> 3)
    let type = t == 31 ? 32 + Int((d[p] & 7) << 3 | (d[p + 1] >> 5)) : t
    return "mp4a.40." + String(type)
  }
  private static func ticks(_ m: Data, track: MovieTrack) throws -> UInt64 {
    func read(_ p: Int64, _ n: Int) throws -> Data {
      guard p >= 0, p <= Int64(m.count - n) else { throw LocalIndexIssue.invalid }
      return m.subdata(in: Int(p)..<Int(p) + n)
    }
    let moof = try LocalAtom.scan(0, Int64(m.count), read: read)[0]
    var total: UInt64 = 0
    for traf in try LocalAtom.scan(moof.body, moof.end, read: read) where traf.kind == "traf" {
      let children = try LocalAtom.scan(traf.body, traf.end, read: read)
      guard let tfhd = children.first(where: { $0.kind == "tfhd" }) else {
        throw LocalIndexIssue.invalid
      }
      let base = Int(tfhd.body)
      let flags = try LocalAtom.uint(m, base + 1, 3)
      guard try LocalAtom.uint(m, base + 4, 4) == track.id else { continue }
      let q = base + 8 + (flags & 1 != 0 ? 8 : 0) + (flags & 2 != 0 ? 4 : 0)
      let def = flags & 8 != 0 ? try LocalAtom.uint(m, q, 4) : track.defaultDuration
      for trun in children where trun.kind == "trun" {
        let b = Int(trun.body)
        let f = try LocalAtom.uint(m, b + 1, 3)
        let count = Int(try LocalAtom.uint(m, b + 4, 4))
        guard count <= 65536 else { throw LocalIndexIssue.invalid }
        var p = b + 8 + (f & 1 != 0 ? 4 : 0) + (f & 4 != 0 ? 4 : 0)
        let step = [0x100, 0x200, 0x400, 0x800].filter { f & UInt64($0) != 0 }.count * 4
        guard p + step * count <= Int(trun.end) else { throw LocalIndexIssue.invalid }
        for _ in 0..<count {
          let dur = f & 0x100 != 0 ? try LocalAtom.uint(m, p, 4) : def
          guard dur > 0, UInt64.max - total >= dur else { throw LocalIndexIssue.invalid }
          total += dur
          p += step
        }
      }
    }
    return total
  }
}
