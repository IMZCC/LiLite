import Foundation

@main enum LegacyDURLCheck {
  static func main() async throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let urls = CommandLine.arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }
    let downloads = root.appendingPathComponent("downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    var videos = [LegacyDURLPlaylist.Rendition](), audios = [LegacyDURLPlaylist.Rendition?]()
    for (n, input) in urls.enumerated() {
      let role = LegacyMediaComponents.component(n)
      precondition(LegacyMediaComponents.isPart(role))
      let data = try Data(contentsOf: input), middle = data.count / 2
      let receipt = OfflinePieces(base: downloads.appendingPathComponent(role), identity: "fixture-\(n)", legacy: true)
      let chunk = downloads.appendingPathComponent("incoming")
      func slice(_ start: Int, _ count: Int) -> OfflinePieces.Slice {
        .init(range: "bytes \(start)-\(start + count - 1)/\(data.count)", requested: "bytes=\(start)-\(start + count - 1)", expected: Int64(count), etag: "\"stable-fixture-\(n)\"")!
      }
      try data.prefix(middle).write(to: chunk)
      guard case .more = try receipt.accept(chunk, slice(0, middle)) else { preconditionFailure() }
      precondition(receipt.state()?.committed == Int64(middle))
      // A crash after writing a block but before committing its receipt must not corrupt resume.
      let tail = try FileHandle(forWritingTo: receipt.partial)
      try tail.seekToEnd(); try tail.write(contentsOf: Data([1, 2, 3])); try tail.close()
      try data.suffix(data.count - middle).write(to: chunk)
      guard case .complete = try receipt.accept(chunk, slice(middle, data.count - middle)) else { preconditionFailure() }
      let restored = try Data(contentsOf: receipt.partial)
      precondition(restored == data)
      let url = downloads.appendingPathComponent(role + ".mp4")
      try FileManager.default.moveItem(at: receipt.partial, to: url); try receipt.clear()
      try await LegacyOfflineMedia.prepare(url)
      let flv = try LegacyOfflineMedia.isFLV(url)
      precondition(!flv)
      let (video, audio) = try LocalMovieFragments.open(LocalMediaFile(url))
      func write(_ index: LocalFragmentIndex, _ lane: String) throws -> LegacyDURLPlaylist.Rendition {
        let base = root.appendingPathComponent("\(n)/\(lane)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try index.file.data(index.initial.lower, Int(index.initial.count)).write(to: base.appendingPathComponent("init.mp4"))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-TARGETDURATION:90", "#EXT-X-MAP:URI=\"init.mp4\""]
        for (i, segment) in index.fragments.enumerated() {
          try index.file.data(segment.bytes.lower, Int(segment.bytes.count)).write(to: base.appendingPathComponent("\(i).m4s"))
          lines += ["#EXTINF:\(segment.seconds),", "\(i).m4s"]
        }
        lines += ["#EXT-X-ENDLIST", ""]
        let list = Data(lines.joined(separator: "\n").utf8)
        return .init(base: base.appendingPathComponent("index.m3u8"), playlist: list,
          duration: index.fragments.reduce(0) { $0 + $1.seconds }, bandwidth: index.bitrate)
      }
      videos.append(try write(video, "v")); audios.append(try audio.map { try write($0, "a") })
    }
    let durations = videos.map(\.duration)
    precondition(LegacyDURLPlaylist.duration(hint: 4.167, measured: 4) == 4.167)
    precondition(LegacyDURLPlaylist.duration(hint: .nan, measured: 4) == 4)
    precondition(LegacyDURLPlaylist.duration(hint: 800, measured: 4) == 4)
    precondition(LegacyMediaComponents.ordered(urls.indices.map(LegacyMediaComponents.component)))
    precondition(!LegacyMediaComponents.ordered(["part-0001", "part-0000"]))
    precondition(!LegacyMediaComponents.isPart("../part-0000") && !LegacyMediaComponents.isPart("part-0256"))
    for (kind, entries) in [("video", videos.map { Optional($0) }), ("audio", audios)] {
      let playlist = try LegacyDURLPlaylist.media(entries, durations: durations)
      try playlist.write(to: root.appendingPathComponent(kind + ".m3u8"))
      let text = String(decoding: playlist, as: UTF8.self)
      precondition(text.components(separatedBy: "#EXT-X-DISCONTINUITY").count == entries.count)
      precondition(text.components(separatedBy: "#EXT-X-ENDLIST").count == 2)
      precondition(!text.contains("URI=\"init.mp4\""))
    }
    let gapped = try LegacyDURLPlaylist.media([audios.first!, nil, audios.last!], durations: [durations[0], 2.75, durations.last!])
    precondition(String(decoding: gapped, as: UTF8.self).contains("#EXT-X-GAP\n#EXTINF:2.75,"))
    do { _ = try LegacyDURLPlaylist.media(videos.map { Optional($0) }, durations: [.nan]); preconditionFailure("invalid timeline accepted") } catch {}
    print("Legacy DURL: \(videos.count) independently indexed parts, initialization discontinuities, audio gaps and unified playlists generated")
  }
}
