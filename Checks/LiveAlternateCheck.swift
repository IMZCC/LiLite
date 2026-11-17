import Foundation

private actor Session {
  let dir: URL
  init(_ dir: URL) { self.dir = dir }
  var hits: [String: Int] = [:]
  func body(_ r: LiveHLSPlaylist.Resource, _ limit: Int) throws -> LiveHLSFetch.Body {
    let name = r.url.lastPathComponent
    hits[name, default: 0] += 1
    var data: Data
    if name.hasSuffix(".m3u8"), name != "master.m3u8" {
      let phase = hits[name] == 1 ? "first-" : "next-"
      data = try Data(contentsOf: dir.appendingPathComponent(phase + name))
    } else {
      data = try Data(contentsOf: dir.appendingPathComponent(name))
    }
    if let b = r.bytes { data = data.subdata(in: Int(b.lower)..<Int(b.upper + 1)) }
    guard data.count <= limit else { throw LivePlaylistError.malformed }
    return .init(url: r.url, data: data)
  }
}
private actor Body {
  var bytes = Data()
  func add(_ d: Data) { bytes.append(d) }
}
@main enum LiveAlternateCheck {
  static func main() async throws {
    let a = CommandLine.arguments
    let base = URL(string: "https://hls.example.invalid/master.m3u8")!
    let s = Session(URL(fileURLWithPath: a[1]))
    let lang = a[2] == "auto" ? "en" : a[2] == "chosen" ? "fr" : "de"
    let pick =
      a[2] == "auto"
      ? nil
      : LiveAudioTrack(
        id: "prior-line", title: lang == "fr" ? "Commentary" : "Packed", language: lang)
    let t = try await LiveHLSFeed.prepare(
      url: base, codec: "avc", origins: [LiveHLSPlaylist.origin(base)!], selected: pick
    ) { r, n in try await s.body(r, n) }
    guard let astream = t.audio else { fatalError("missing audio rendition") }
    precondition(
      t.choices.count >= 2 && t.selection?.language == lang && t.dateDelta == Int64(a[5])!)
    precondition(t.head.id != astream.head.id)
    let v = Body()
    let sound = Body()
    async let video: Void = t.run { await v.add($0) }
    async let audio: Void = astream.run { await sound.add($0) }
    _ = try await (video, audio)
    try await v.bytes.write(to: URL(fileURLWithPath: a[3]))
    try await sound.bytes.write(to: URL(fileURLWithPath: a[4]))
    let hits = await s.hits
    let selected = lang + ".m3u8"
    let other = lang == "en" ? "fr.m3u8" : "en.m3u8"
    precondition(hits["v.m3u8"] == 2 && hits[selected] == 2 && hits[other] == nil)
    if a.count > 6 {
      precondition(astream.origin90 == Int64(a[6])!)
      precondition(astream.demux >= 3)
    }
    let reopened = try await LiveHLSFeed.prepare(
      url: base, codec: "avc", origins: [LiveHLSPlaylist.origin(base)!], selected: t.selection
    ) { r, n in try await s.body(r, n) }
    guard let reopenedSound = reopened.audio else { fatalError() }
    precondition(
      reopened.head.id > t.head.id && reopenedSound.head.id > astream.head.id
        && reopened.selection == t.selection)
    let rv = Body()
    let ra = Body()
    async let rvid: Void = reopened.run { await rv.add($0) }
    async let rsnd: Void = reopenedSound.run { await ra.add($0) }
    _ = try await (rvid, rsnd)
    try await rv.bytes.write(to: URL(fileURLWithPath: a[3] + ".again"))
    try await ra.bytes.write(to: URL(fileURLWithPath: a[4] + ".again"))
    try (String(reopened.dateDelta) + "," + String(reopenedSound.origin90 ?? -1)).write(
      toFile: a[3] + ".clock", atomically: true, encoding: .utf8)
    print(
      "Independent live playlists: \(t.selection!.title); distinct sequence numbers, two reloads and date delta \(t.dateDelta) 纰宻"
    )
  }
}
