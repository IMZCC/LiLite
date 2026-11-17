import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
@main enum RemoteMovieCheck {
  static func main() async throws {
    let args = CommandLine.arguments
    let endpoint = URL(string: args[1])!
    precondition(endpoint.host == "127.0.0.1")
    let transport = RangeTransport()
    defer { transport.close() }
    @Sendable func fetch(_ a: Int64, _ n: Int) async throws -> (data: Data, total: Int64) {
      var r = URLRequest(url: endpoint)
      r.setValue("bytes=\(a)-\(a+Int64(n)-1)", forHTTPHeaderField: "Range")
      let v = try await transport.response(r, limit: n)
      return (v.data, v.total)
    }
    let m = try await RemoteMovieMetadata.open(fetch: fetch)
    let (v, a) = try LocalMovieFragments.open(m)
    guard let a else { fatalError("missing audio") }
    let file = try LocalMediaFile(URL(fileURLWithPath: args[2]))
    let (lv, la) = try LocalMovieFragments.open(file)
    for (l, t) in [(lv, v), (la!, a)] {
      let n = t.fragments.count / 2
      let r = t.fragments[n].bytes
      guard let mapped = t.file as? LocalMovieFragments else { fatalError() }
      let want = try l.file.data(r.lower, Int(r.count))
      func read(_ start: Int64, _ n: Int) async throws -> Data {
        try await mapped.online(start, n) { a, n in try await fetch(a, n).data }
      }
      let got = try await read(r.lower, Int(r.count))
      precondition(want == got)
      let clipped = try await read(r.lower + 13, Int(r.count) - 31)
      precondition(clipped == Data(want.dropFirst(13).dropLast(18)))
      let map = try await read(0, Int(t.initial.count))
      if l.codec == lv.codec {
        let decoded = try await DecoderSegment.convert(
          initial: map, media: got, source: r.lower, target: r.lower, index: n, route: .software)
        try (decoded.initial + decoded.media).write(to: URL(fileURLWithPath: args[3]))
      }

    }
    print(
      "HTTP Range: independent video/audio and partial seek bytes matched the file; the non-zero video fragment was software-decoded"
    )
  }
}
