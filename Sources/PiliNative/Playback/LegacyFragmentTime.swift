import Foundation

/// Preserve a sparse FLV window's position in the movie while its local decoder sees bounded data.
enum LegacyFragmentTime {
  static func shifted(_ media: Data, initial: Data, seconds: Double) throws -> Data {
    guard seconds.isFinite, seconds >= 0 else { throw LocalIndexIssue.invalid }
    if seconds == 0 { return media }
    func atoms(_ bytes: Data, _ a: Int64, _ b: Int64) throws -> [LocalAtom] {
      try LocalAtom.scan(a, b) { at, count in bytes.subdata(in: Int(at)..<Int(at) + count) }
    }
    func child(_ bytes: Data, _ parent: LocalAtom?, _ name: String) throws -> LocalAtom {
      guard let found = try atoms(bytes, parent?.body ?? 0, parent?.end ?? Int64(bytes.count)).first(where: { $0.kind == name }) else { throw LocalIndexIssue.invalid }
      return found
    }
    let moov = try child(initial, nil, "moov"), trak = try child(initial, moov, "trak")
    let mdia = try child(initial, trak, "mdia"), mdhd = try child(initial, mdia, "mdhd")
    let version = try LocalAtom.uint(initial, Int(mdhd.body), 1)
    let scale = try LocalAtom.uint(initial, Int(mdhd.body) + (version == 1 ? 20 : 12), 4)
    guard scale > 0, seconds * Double(scale) < Double(UInt64.max) else { throw LocalIndexIssue.invalid }
    let ticks = UInt64((seconds * Double(scale)).rounded())
    var result = media
    for moof in try atoms(media, 0, Int64(media.count)) where moof.kind == "moof" {
      for traf in try atoms(media, moof.body, moof.end) where traf.kind == "traf" {
        for tfdt in try atoms(media, traf.body, traf.end) where tfdt.kind == "tfdt" {
          let version = try LocalAtom.uint(media, Int(tfdt.body), 1), width = version == 1 ? 8 : 4
          guard version <= 1 else { throw LocalIndexIssue.invalid }
          let position = Int(tfdt.body) + 4, current = try LocalAtom.uint(media, position, width)
          guard current <= UInt64.max - ticks, width == 8 || current + ticks <= UInt32.max else { throw LocalIndexIssue.invalid }
          let value = current + ticks
          for n in 0..<width { result[position + n] = UInt8(truncatingIfNeeded: value >> ((width - n - 1) * 8)) }
        }
      }
    }
    return result
  }
}
