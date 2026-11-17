import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let u = request.url!
    let name = u.lastPathComponent
    precondition(
      u.host == "media.fixture.invalid" && request.value(forHTTPHeaderField: "Cookie") == nil)
    precondition(request.value(forHTTPHeaderField: "Referer") == "https://live.bilibili.com/123")
    var headers: [String: String] = [:]
    let status: Int
    let data: Data
    switch name {
    case "ok", "wrong":
      precondition(request.value(forHTTPHeaderField: "Range") == "bytes=10-19")
      status = 206
      data = Data(repeating: 0x41, count: 10)
      headers["Content-Range"] = name == "ok" ? "bytes 10-19/100" : "bytes 20-29/100"
    case "too-many":
      status = 200
      data = Data(repeating: 0x42, count: 1001)
    default:
      status = 403
      data = Data()
    }
    let r = HTTPURLResponse(
      url: u, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
    if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

private actor Fixture {
  let root: URL
  var names: [String] = []
  var bytes = Data()
  init(_ dir: URL) { root = dir }
  func supply(_ r: LiveHLSPlaylist.Resource, _ limit: Int) throws -> LiveHLSFetch.Body {
    let name = r.url.lastPathComponent
    names.append(name)
    let data: Data
    if name == "master.m3u8" {
      data = Data(
        "#EXTM3U\n#EXT-X-STREAM-INF:CODECS=\"avc1.42E01F,mp4a.40.2\",BANDWIDTH=400000\nindex.m3u8\n"
          .utf8)
    } else {
      let d = try Data(contentsOf: root.appendingPathComponent(name))
      if let b = r.bytes { data = d.subdata(in: Int(b.lower)..<Int(b.upper + 1)) } else { data = d }
    }
    guard data.count <= limit else { throw URLError(.badServerResponse) }
    return .init(url: r.url, data: data)
  }
  func put(_ d: Data) { bytes.append(d) }
}
@main enum LiveHLSFeedCheck {
  static func main() async throws {
    let a = CommandLine.arguments
    let base = URL(string: "https://media.fixture.invalid/master.m3u8")!
    let hosts = Set([LiveHLSPlaylist.origin(base)!])
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FixtureProtocol.self]
    let net = LiveHLSFetch(room: 123, origins: hosts, configuration: config)
    defer { net.close() }
    func resource(_ name: String) -> LiveHLSPlaylist.Resource {
      .init(
        url: base.deletingLastPathComponent().appendingPathComponent(name),
        bytes: ["ok", "wrong"].contains(name) ? ByteSpan(10, 19) : nil)
    }
    let fetched = try await net.read(resource("ok"), limit: 10)
    precondition(fetched.data == Data(repeating: 0x41, count: 10))
    do {
      _ = try await net.read(resource("wrong"), limit: 10)
      fatalError()
    } catch LivePlaylistError.malformed {}
    do {
      _ = try await net.read(resource("denied"), limit: 8)
      fatalError()
    } catch LivePlaylistError.denied(403) {}
    do {
      _ = try await net.read(resource("too-many"), limit: 1000)
      fatalError()
    } catch { precondition(error is URLError || error is LivePlaylistError) }
    let source = Fixture(URL(fileURLWithPath: a[1]))
    let dst = URL(fileURLWithPath: a[2])
    let format = Int32(a[3])!
    let h = try await LiveHLSFeed.prepare(url: base, codec: "avc", origins: hosts) { r, n in
      try await source.supply(r, n)
    }
    precondition(h.demux == format)
    try await h.run { d in await source.put(d) }
    let bytes = await source.bytes
    try bytes.write(to: dst)
    let names = await source.names
    precondition(names.prefix(2).elementsEqual(["master.m3u8", "index.m3u8"]) && names.count >= 4)
    for (extra, expected) in [
      ("#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:2,\npart.ts", "protected"),
      ("#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI=\"skd://example\"", "protected"),
      (
        "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",URI=\"audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=20000,AUDIO=\"a\"\nvid.m3u8",
        "audio"
      ),
      ("#EXTINF:2,\nhttps://elsewhere.invalid/secret.ts", "origin"),
    ] {
      let body = Data(("#EXTM3U\n" + extra + "\n").utf8)
      do {
        _ = try await LiveHLSFeed.prepare(url: base, codec: "avc", origins: hosts) { r, _ in
          precondition(r.url == base, "A key, foreign origin or unpaired rendition was fetched")
          return .init(url: base, data: body)
        }
        fatalError("unsafe variant accepted")
      } catch LivePlaylistError.protectedMedia {
        precondition(expected == "protected")
      } catch LivePlaylistError.separateAudio {
        precondition(expected == "audio")
      } catch LivePlaylistError.malformed { precondition(expected == "origin") }
    }
    let by = Data(
      "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:9\n#EXT-X-BYTERANGE:7@4\n#EXTINF:2,\nshared.ts\n#EXT-X-BYTERANGE:3\n#EXTINF:2,\nshared.ts\n#EXT-X-ENDLIST"
        .utf8)
    let aligned = try LiveHLSPlaylist(data: by, base: base, origins: hosts)
    precondition(
      aligned.media.map(\.id) == [9, 10] && aligned.media[1].media.bytes == ByteSpan(11, 13))
    print(
      "Live playlist demux \(format): \(names.count) bounded fetches, \(bytes.count) payload bytes; encryption, incomplete audio declarations and foreign origins rejected before fetch"
    )
  }
}
