import Foundation

/// Each random-access encode has its own AVC configuration. Publish the matching map and fragment;
/// assign the playlist's sequence number to mfhd so arbitrary seeks do not restart the counter.
struct DecoderFragment {
  static func request(_ name: String) -> (index: Int, initial: Bool)? {
    let initial = name.hasPrefix("init-") && name.hasSuffix(".mp4")
    guard initial || name.hasSuffix(".m4s") else { return nil }
    let digits = initial ? name.dropFirst(5).dropLast(4) : name.dropLast(4)
    guard !digits.isEmpty, digits.utf8.count <= 8,
      digits.utf8.allSatisfy({ (48...57).contains($0) }), let i = Int(digits)
    else { return nil }
    return (i, initial)
  }
  struct Encoding {
    let codec: String?, width: Int, height: Int, range: String
  }
  let initial: Data, media: Data
  let encoding: Encoding
  var count: Int { initial.count + media.count }
  init(_ source: Data, index: Int, transfer: Int32 = 1, audio: Bool = false) throws {
    guard index >= 0, index < Int(UInt32.max), source.count >= 24, source.count <= 48 * 1024 * 1024
    else { throw URLError(.cannotDecodeContentData) }
    let b = source.startIndex
    typealias Box = (start: Int, end: Int, tag: String)
    func value(_ at: Int) -> UInt32 {
      (UInt32(source[b + at]) << 24) | (UInt32(source[b + at + 1]) << 16)
        | (UInt32(source[b + at + 2]) << 8) | UInt32(source[b + at + 3])
    }
    func boxes(_ start: Int, _ end: Int) throws -> [Box] {
      var list: [Box] = []
      var pos = start
      while pos < end {
        guard end - pos >= 8 else { throw URLError(.cannotDecodeContentData) }
        let n = Int(value(pos))
        guard n >= 8, n <= end - pos, list.count < 128 else {
          throw URLError(.cannotDecodeContentData)
        }
        list.append(
          (pos, pos + n, String(decoding: source[b + pos + 4..<b + pos + 8], as: UTF8.self)))
        pos += n
      }
      return list
    }
    let headers = try boxes(0, source.count)
    guard headers.first?.tag == "ftyp", let moov = headers.first(where: { $0.tag == "moov" }),
      let moof = headers.first(where: { $0.tag == "moof" }), moov.end <= moof.start,
      headers.filter({ $0.tag == "moof" }).count == 1, headers.last?.tag == "mdat",
      let mfhd = try boxes(moof.start + 8, moof.end).first(where: { $0.tag == "mfhd" }),
      mfhd.end - mfhd.start >= 16
    else { throw URLError(.cannotDecodeContentData) }
    var codec: String?
    var w = 0
    var h = 0
    if !audio, let trak = try boxes(moov.start + 8, moov.end).first(where: { $0.tag == "trak" }),
      let mdia = try boxes(trak.start + 8, trak.end).first(where: { $0.tag == "mdia" }),
      let minf = try boxes(mdia.start + 8, mdia.end).first(where: { $0.tag == "minf" }),
      let stbl = try boxes(minf.start + 8, minf.end).first(where: { $0.tag == "stbl" }),
      let stsd = try boxes(stbl.start + 8, stbl.end).first(where: { $0.tag == "stsd" }),
      stsd.end - stsd.start >= 16,
      let entry = try boxes(stsd.start + 16, stsd.end).first, entry.end - entry.start >= 86
    {
      let at = b + entry.start
      w = Int(source[at + 32]) * 256 + Int(source[at + 33])
      h = Int(source[at + 34]) * 256 + Int(source[at + 35])
      let configs = try boxes(entry.start + 86, entry.end)
      if let cfg = configs.first(where: { $0.tag == "avcC" }), cfg.end - cfg.start >= 12 {
        let a = b + cfg.start + 8
        codec =
          "avc1." + String(format: "%02X%02X%02X", source[a + 1], source[a + 2], source[a + 3])
      } else if let cfg = configs.first(where: { $0.tag == "hvcC" }), cfg.end - cfg.start >= 21 {
        let a = b + cfg.start + 8
        let head = source[a + 1]
        let level = source[a + 12]
        let profile = ["", "A", "B", "C"][Int(head >> 6)] + String(head & 31)
        var compat: UInt32 = 0
        var raw = value(cfg.start + 10)
        for _ in 0..<32 {
          compat = (compat << 1) | (raw & 1)
          raw >>= 1
        }
        var constraint = Array(source[a + 6...a + 11])
        while constraint.last == 0 { constraint.removeLast() }
        let suffix = constraint.map { String(format: ".%02X", $0) }.joined()
        codec =
          "hvc1." + profile + "." + String(compat, radix: 16, uppercase: true) + "."
          + (head & 32 == 0 ? "L" : "H") + String(level) + suffix
      }
    }
    encoding = .init(
      codec: audio ? "alac" : codec, width: w, height: h,
      range: transfer == 16 ? "PQ" : transfer == 18 ? "HLG" : "SDR")
    initial = source.subdata(in: b..<b + moof.start)
    var body = source.subdata(in: b + moof.start..<source.endIndex)
    let seq = UInt32(index + 1)
    let at = body.startIndex + mfhd.start - moof.start + 12
    for i in 0..<4 { body[at + i] = UInt8(truncatingIfNeeded: seq >> ((3 - i) * 8)) }
    media = body
  }
}
