/// Classic MP4 sample tables. Only metadata is loaded; each compressed sample must be inside
/// the mdat of the already-open file. An external or encrypted track never becomes an input.
import Foundation

struct MovieSample {
  var position: Int64 = 0
  var size: UInt32 = 0, duration: UInt32 = 0, composition: UInt32 = 0
  var key = false
}
struct LocalMovieTable {
  let source: any LocalTrackBytes
  let video: Bool, id: UInt32, scale: UInt32
  let mvhd: Data, tkhd: Data, edit: Data, mdhd: Data, hdlr: Data, minfHead: Data, stsd: Data
  let samples: [MovieSample]
  static func load(_ file: any LocalTrackBytes,requiringVideo:Bool=true) throws -> [LocalMovieTable] {
    let top = try LocalAtom.scan(0, file.length, read: file.data)
    guard let moov = top.first(where: { $0.kind == "moov" }), moov.size <= 24 * 1024 * 1024,
      !top.contains(where: { $0.kind == "moof" })
    else { throw LocalIndexIssue.notFragmented }
    let media = top.filter { $0.kind == "mdat" }
    guard !media.isEmpty else { throw LocalIndexIssue.invalid }
    let m = try file.data(moov.start, Int(moov.size))
    let p = MovieBoxes(m)
    let root = try p.list(0, Int64(m.count))[0]
    let mvhd = try p.one(root, "mvhd")
    let all = try p.children(root)
    guard !all.contains(where: { $0.kind == "pssh" }) else { throw LocalIndexIssue.encrypted }
    var result: [LocalMovieTable] = []
    for track in all where track.kind == "trak" {
      let mdia = try p.one(track, "mdia")
      let handler = try p.one(mdia, "hdlr")
      let kind = try p.number(handler, 8)
      if kind != 0x736f_756e && kind != 0x7669_6465 { continue }
      if result.contains(where: { $0.video == (kind == 0x7669_6465) }) {
        throw LocalIndexIssue.invalid
      }
      result.append(
        try .init(
          file: file, m: m, media: media, p: p, trak: track, mdia: mdia, hdlr: handler, mvhd: mvhd,
          video: kind == 0x7669_6465))
    }
    guard !result.isEmpty,(!requiringVideo || result.contains(where: { $0.video })) else { throw LocalIndexIssue.invalid }
    return result
  }
  private init(
    file: any LocalTrackBytes, m: Data, media: [LocalAtom], p: MovieBoxes,
    trak: LocalAtom, mdia: LocalAtom, hdlr: LocalAtom, mvhd: LocalAtom, video: Bool
  ) throws {
    self.video = video
    self.source = file
    let tk = try p.one(trak, "tkhd")
    let md = try p.one(mdia, "mdhd")
    self.id = try p.number(tk, p.number(tk, 0, 1) == 1 ? 20 : 12)
    self.scale = try p.number(md, p.number(md, 0, 1) == 1 ? 20 : 12)
    guard id > 0, scale > 0 else { throw LocalIndexIssue.invalid }
    self.mvhd = p.whole(mvhd)
    self.tkhd = p.whole(tk)
    self.mdhd = p.whole(md)
    self.hdlr = p.whole(hdlr)
    let ctl = try p.children(trak).first { $0.kind == "edts" }
    if let ctl {
      let e = try p.one(ctl, "elst")
      let version = try p.number(e, 0, 1)
      let entries = Int(try p.number(e, 4))
      let w = version == 1 ? 8 : 4
      guard version <= 1, (1...2).contains(entries) else { throw LocalIndexIssue.invalid }
      for i in 0..<entries {
        let base = 8 + i * (2 * w + 4)
        let start = try p.big(e, base + w, w)
        guard try p.number(e, base + 2 * w, 4) == 0x0001_0000,
          entries == 1
            || (i == 0
              ? start == (w == 8 ? UInt64.max : UInt64(UInt32.max))
              : start <= UInt64(Int64.max) && (w == 8 || start <= UInt64(Int32.max)))
        else { throw LocalIndexIssue.invalid }
      }
      edit = p.whole(ctl)
    } else {
      edit = Data()
    }
    let minf = try p.one(mdia, "minf")
    let stbl = try p.one(minf, "stbl")
    let stsd = try p.one(stbl, "stsd")
    let dinf = try p.one(minf, "dinf")
    let dref = try p.one(dinf, "dref")
    let refs = try p.children(dref, skip: 8)
    guard refs.count == 1, refs[0].kind == "url ", try p.number(refs[0], 0) == 1,
      refs[0].size == refs[0].head + 4
    else { throw LocalIndexIssue.external }
    let e = try p.children(stsd, skip: 8)
    guard e.count == 1 else { throw LocalIndexIssue.invalid }
    guard try p.number(e[0], 6, 2) == 1 else { throw LocalIndexIssue.external }
    if ["encv", "enca", "drmi", "drms"].contains(e[0].kind) { throw LocalIndexIssue.encrypted }
    let clear = try p.children(stbl)
    for b in clear {
      if ["senc", "saiz", "saio"].contains(b.kind)
        || (b.kind == "sgpd" && (try? p.number(b, 4)) == 0x7365_6967)
      {
        throw LocalIndexIssue.encrypted
      }
    }
    self.stsd = p.whole(stsd)
    self.minfHead = try p.whole(p.one(minf, video ? "vmhd" : "smhd")) + p.whole(dinf)
    guard let sizeBox = clear.first(where: { $0.kind == "stsz" || $0.kind == "stz2" }) else {
      throw LocalIndexIssue.invalid
    }
    let compact = sizeBox.kind == "stz2"
    let bits = compact ? Int(try p.number(sizeBox, 7, 1)) : 32
    let fixed = compact ? 0 : try p.number(sizeBox, 4)
    let count = Int(try p.number(sizeBox, 8))
    guard [4, 8, 16, 32].contains(bits), !compact || bits < 32, count > 0, count <= 512_000,
      fixed != 0 || Int64((count * bits + 7) / 8) <= sizeBox.end - sizeBox.body - 12
    else { throw LocalIndexIssue.invalid }
    var rows = [MovieSample](repeating: .init(), count: count)
    for i in rows.indices {
      let sz: UInt32
      if fixed > 0 {
        sz = fixed
      } else if bits == 4 {
        let pair = try p.number(sizeBox, 12 + i / 2, 1)
        sz = i % 2 == 0 ? pair >> 4 : pair & 15
      } else {
        sz = try p.number(sizeBox, 12 + i * (bits / 8), bits / 8)
      }
      guard sz > 0, sz <= 32 * 1024 * 1024 else { throw LocalIndexIssue.invalid }
      rows[i].size = sz
    }
    func fill(_ box: LocalAtom, _ assign: (inout MovieSample, UInt32) -> Void) throws {
      let n = try p.rows(box, stride: 8, max: count)
      var cursor = 0
      for j in 0..<n {
        let l = Int(try p.number(box, 8 + j * 8))
        let v = try p.number(box, 12 + j * 8)
        guard l > 0, l <= rows.count - cursor else { throw LocalIndexIssue.invalid }
        for i in cursor..<cursor + l { assign(&rows[i], v) }
        cursor += l
      }
      guard cursor == count else { throw LocalIndexIssue.invalid }
    }
    try fill(p.one(stbl, "stts")) { $0.duration = $1 }
    guard rows.allSatisfy({ $0.duration > 0 }) else { throw LocalIndexIssue.invalid }
    if let ct = clear.first(where: { $0.kind == "ctts" }) {
      let ver = try p.number(ct, 0, 1)
      guard ver <= 1 else { throw LocalIndexIssue.invalid }
      try fill(ct) { $0.composition = $1 }
      if ver == 0 && rows.contains(where: { $0.composition > UInt32(Int32.max) }) {
        throw LocalIndexIssue.invalid
      }
    }
    if let key = clear.first(where: { $0.kind == "stss" }) {
      let n = try p.rows(key, stride: 4, max: count)
      for j in 0..<n {
        let i = Int(try p.number(key, 8 + j * 4)) - 1
        guard rows.indices.contains(i) else { throw LocalIndexIssue.invalid }
        rows[i].key = true
      }
    } else {
      for i in rows.indices { rows[i].key = true }
    }
    guard rows[0].key else { throw LocalIndexIssue.invalid }
    let stsc = try p.one(stbl, "stsc")
    guard let offsets = clear.first(where: { $0.kind == "stco" || $0.kind == "co64" }) else {
      throw LocalIndexIssue.invalid
    }
    let w = offsets.kind == "co64" ? 8 : 4
    let chunks = try p.rows(offsets, stride: w, max: count)
    let mappings = try p.rows(stsc, stride: 12, max: chunks)
    var next = 0
    var per = 0
    var cursor = 0
    for chunk in 1...chunks {
      if chunk & 4095 == 0 { try Task.checkCancellation() }
      if next < mappings {
        let start = Int(try p.number(stsc, 8 + next * 12))
        guard start >= chunk, start <= chunks else { throw LocalIndexIssue.invalid }
        if start == chunk {
          per = Int(try p.number(stsc, 12 + next * 12))
          guard try p.number(stsc, 16 + next * 12) == 1 else { throw LocalIndexIssue.invalid }
          next += 1
        }
      }
      let raw = try p.big(offsets, 8 + (chunk - 1) * w, w)
      guard raw < UInt64(file.length), per > 0, per <= count - cursor else {
        throw LocalIndexIssue.invalid
      }
      var offset = Int64(raw)
      for i in cursor..<cursor + per {
        rows[i].position = offset
        offset += Int64(rows[i].size)
      }
      // mdat boxes are sorted by file position; the container may legitimately have multiple.
      var lo = 0
      var hi = media.count
      while lo < hi {
        let mid = (lo + hi) / 2
        if media[mid].end <= Int64(raw) { lo = mid + 1 } else { hi = mid }
      }
      guard lo < media.count, Int64(raw) >= media[lo].body, offset <= media[lo].end else {
        throw LocalIndexIssue.invalid
      }
      cursor += per
    }
    guard cursor == count, next == mappings else { throw LocalIndexIssue.invalid }
    samples = rows
  }
}
struct MovieBoxes {
  let m: Data
  init(_ data: Data) { m = data }
  func list(_ lower: Int64, _ upper: Int64) throws -> [LocalAtom] {
    try LocalAtom.scan(lower, upper) { at, n in
      guard at >= 0, at <= Int64(m.count - n) else { throw LocalIndexIssue.invalid }
      return m.subdata(in: Int(at)..<Int(at) + n)
    }
  }
  func whole(_ box: LocalAtom) -> Data { m.subdata(in: Int(box.start)..<Int(box.end)) }
  func children(_ box: LocalAtom, skip: Int64 = 0) throws -> [LocalAtom] {
    try list(box.body + skip, box.end)
  }
  func one(_ box: LocalAtom, _ name: String) throws -> LocalAtom {
    guard let result = try children(box).first(where: { $0.kind == name }) else {
      throw LocalIndexIssue.invalid
    }
    return result
  }
  func big(_ b: LocalAtom, _ at: Int, _ n: Int) throws -> UInt64 {
    guard at >= 0, b.body + Int64(at + n) <= b.end else { throw LocalIndexIssue.invalid }
    return try LocalAtom.uint(m, Int(b.body) + at, n)
  }
  func number(_ b: LocalAtom, _ at: Int, _ n: Int = 4) throws -> UInt32 {
    guard n <= 4 else { throw LocalIndexIssue.invalid }
    return UInt32(try big(b, at, n))
  }
  func rows(_ b: LocalAtom, stride: Int, max: Int) throws -> Int {
    let n = Int(try number(b, 4))
    guard n > 0, n <= max, Int64(n * stride) <= b.end - b.body - 8 else {
      throw LocalIndexIssue.invalid
    }
    return n
  }
}
