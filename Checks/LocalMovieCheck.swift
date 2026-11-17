import Foundation

private final class Meter: LocalTrackBytes, @unchecked Sendable {
  let file: LocalMediaFile
  private(set) var reads: [Range<Int64>] = []
  let lock = NSLock()
  init(_ url: URL) throws { file = try LocalMediaFile(url) }
  var length: Int64 { file.length }
  func data(_ start: Int64, _ count: Int) throws -> Data {
    lock.withLock { reads.append(start..<start + Int64(count)) }
    return try file.data(start, count)
  }
}
@main enum LocalMovieCheck {
  static func main() async throws {
    let args = CommandLine.arguments
    func url(_ i: Int) -> URL { URL(fileURLWithPath: args[i]) }
    let meter = try Meter(url(1))
    let file = meter.file
    let regions = try LocalAtom.scan(0, file.length, read: file.data).filter { $0.kind == "mdat" }
    let (v, a) = try LocalMovieFragments.open(meter)
    guard let a, v.fragments.count >= 3, a.fragments.count >= 3 else {
      fatalError("not enough segments")
    }
    guard
      !meter.reads.contains(where: { r in regions.contains(where: { r.overlaps($0.body..<$0.end) })
        })
    else { fatalError("scanned the movie payload") }
    let n = v.fragments.count / 2
    let span = v.fragments[n].bytes
    let initV = try v.file.data(0, Int(v.initial.count))
    let middle = try v.file.data(span.lower, Int(span.count))
    let out = try await DecoderSegment.convert(
      initial: initV, media: middle, source: span.lower, target: span.lower, index: n,
      route: .software)
    try (out.initial + out.media).write(to: url(2))
    try (initV + middle).write(to: url(3))
    func save(_ track: LocalFragmentIndex, _ url: URL) throws {
      var all = try track.file.data(0, Int(track.initial.count))
      for frag in track.fragments {
        all.append(try track.file.data(frag.bytes.lower, Int(frag.bytes.count)))
      }
      try all.write(to: url)
    }
    try save(v, url(4))
    try save(a, url(5))
    do {
      _ = try LocalMovieFragments.open(LocalMediaFile(url(6)))
      fatalError("encrypted sample entry accepted")
    } catch LocalIndexIssue.encrypted {}
    do {
      _ = try LocalMovieFragments.open(LocalMediaFile(url(7)))
      fatalError("external media reference accepted")
    } catch LocalIndexIssue.external {}
    print(
      "Classic MP4: \(v.codec), \(v.fragments.count) video / \(a.fragments.count) audio ranges, open touched zero mdat bytes, seek converted fragment \(n)"
    )
  }
}
