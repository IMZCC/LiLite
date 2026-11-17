import Foundation

enum LivePlaylistError: LocalizedError {
  case malformed, protectedMedia, separateAudio, discontinuity
  case denied(Int)
  var errorDescription: String? {
    switch self {
    case .protectedMedia: return "此直播使用受保护的播放线路"
    case .separateAudio: return "此直播的独立音轨需要系统播放"
    case .discontinuity: return "直播时间线已更新"
    case .denied(let c): return "直播服务器拒绝了请求（\(c)）"
    case .malformed: return "无法读取直播播放列表"
    }
  }
}
struct LiveAudioTrack: Identifiable, Hashable {
  let id: String, title: String, language: String?
  static func match(_ wanted: Self, in options: [Self]) -> Self? {
    if let exact = options.first(where: { $0.id == wanted.id }) { return exact }
    if let name = options.first(where: {
      $0.title == wanted.title && $0.language == wanted.language
    }) {
      return name
    }
    if let l = wanted.language {
      let possible = options.filter { $0.language?.lowercased() == l.lowercased() }
      if possible.count == 1 { return possible[0] }
    }
    return nil
  }
}
struct LiveHLSPlaylist {
  struct Resource: Equatable { let url: URL, bytes: ByteSpan? }
  struct Segment {
    let id: Int64, media: Resource, initial: Resource?, epoch: Int64, gap: Bool, seconds: Double
    var date: Date?
  }
  struct Variant { let url: URL, group: String?, codecs: String }
  struct Audio {
    let group: String, choice: LiveAudioTrack, url: URL?, preferred: Bool, automatic: Bool
  }
  let renditions: [Audio]
  let variants: [Variant], external: Set<String>, media: [Segment], target: Double, finished: Bool
  static func origin(_ u: URL) -> String? {
    guard u.scheme?.lowercased() == "https", let host = u.host?.lowercased(), !host.isEmpty,
      u.user == nil, u.password == nil, u.fragment == nil,
      !host.contains("%")
    else { return nil }
    return host + ":" + String(u.port ?? 443)
  }
  static func url(_ raw: String, base: URL, origins: Set<String>) throws -> URL {
    guard !raw.isEmpty, raw.utf8.count <= 8192, !raw.contains("{$"),
      !raw.utf8.contains(where: { $0 < 32 || $0 == 127 }),
      let url = URL(string: raw, relativeTo: base)?.absoluteURL, let host = origin(url),
      origins.contains(host)
    else { throw LivePlaylistError.malformed }
    return url
  }
  private static func attrs(_ raw: Substring) throws -> [String: String] {
    var s = raw
    var out: [String: String] = [:]
    while !s.isEmpty {
      guard out.count < 40, let eq = s.firstIndex(of: "=") else {
        throw LivePlaylistError.malformed
      }
      let key = String(s[..<eq])
      s = s[s.index(after: eq)...]
      let value: String
      if s.first == "\"" {
        s = s.dropFirst()
        guard let end = s.firstIndex(of: "\"") else { throw LivePlaylistError.malformed }
        value = String(s[..<end])
        s = s[s.index(after: end)...]
      } else if let comma = s.firstIndex(of: ",") {
        value = String(s[..<comma])
        s = s[comma...]
      } else {
        value = String(s)
        s = ""
      }
      guard !key.isEmpty, !value.isEmpty, out[key] == nil else { throw LivePlaylistError.malformed }
      out[key] = value
      if !s.isEmpty {
        guard s.first == "," else { throw LivePlaylistError.malformed }
        s = s.dropFirst()
      }
    }
    return out
  }
  init(data: Data, base: URL, origins: Set<String>) throws {
    guard data.count <= 512 * 1024, let text = String(data: data, encoding: .utf8) else {
      throw LivePlaylistError.malformed
    }
    let lines = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard lines.first == "#EXTM3U", lines.count < 12000 else { throw LivePlaylistError.malformed }
    var v: [Variant] = []
    var groups = Set<String>()
    var tracks: [Segment] = []
    var variant: [String: String]?
    var initial: Resource?
    var last: Resource?
    var ns: Int64 = 0
    var epoch: Int64 = 0
    var declared = false
    var range: String?
    var gap = false
    var alternatives: [Audio] = []
    var stamp: Date?
    var step = 0.0
    let dateReader = ISO8601DateFormatter()
    let wholeDate = ISO8601DateFormatter()
    dateReader.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var duration = 3.0
    var end = false
    func res(_ value: String, _ raw: String?, previous: Resource?) throws -> Resource {
      let u = try Self.url(value, base: base, origins: origins)
      guard let raw else { return .init(url: u, bytes: nil) }
      let parts = raw.split(separator: "@", omittingEmptySubsequences: false)
      guard (1...2).contains(parts.count), let n = Int64(parts[0]), n > 0, n <= 32 * 1024 * 1024
      else { throw LivePlaylistError.malformed }
      let start: Int64
      if parts.count == 2, let at = Int64(parts[1]) {
        start = at
      } else if parts.count == 1, let prev = previous, prev.url == u, let span = prev.bytes {
        start = span.upper + 1
      } else {
        throw LivePlaylistError.malformed
      }
      guard start >= 0, start < Int64.max - n else { throw LivePlaylistError.malformed }
      return .init(url: u, bytes: ByteSpan(start, start + n - 1))
    }
    for line in lines.dropFirst() {
      guard line.utf8.count <= 8192 else { throw LivePlaylistError.malformed }
      let tail =
        line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).last ?? ""
      if line == "#EXT-X-I-FRAMES-ONLY" || line.hasPrefix("#EXT-X-SKIP:") {
        throw LivePlaylistError.malformed
      }
      if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:") {
        guard try Self.attrs(tail)["METHOD"] == "NONE" else {
          throw LivePlaylistError.protectedMedia
        }
      } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
        variant = try Self.attrs(tail)
      } else if line.hasPrefix("#EXT-X-MEDIA:") {
        let a = try Self.attrs(tail)
        if a["TYPE"] == "AUDIO" {
          guard let id = a["GROUP-ID"], let name = a["NAME"], alternatives.count < 48,
            id.utf8.count <= 200, name.utf8.count <= 200
          else { throw LivePlaylistError.separateAudio }
          let lang = a["LANGUAGE"]
          let choice = LiveAudioTrack(
            id: [id, name, lang ?? ""].map { String($0.utf8.count) + ":" + $0 }.joined(),
            title: name, language: lang)
          guard !alternatives.contains(where: { $0.choice.id == choice.id }) else {
            throw LivePlaylistError.malformed
          }
          let url = try a["URI"].map { try Self.url($0, base: base, origins: origins) }
          if url != nil { groups.insert(id) }
          alternatives.append(
            .init(
              group: id, choice: choice, url: url, preferred: a["DEFAULT"] == "YES",
              automatic: a["AUTOSELECT"] == "YES"))
        }
      } else if line.hasPrefix("#EXT-X-MAP:") {
        let vals = try Self.attrs(tail)
        guard let uri = vals["URI"] else { throw LivePlaylistError.malformed }
        initial = try res(uri, vals["BYTERANGE"], previous: initial)
      } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
        guard tracks.isEmpty, let seq = Int64(tail), seq >= 0, seq < Int64.max - 20000 else {
          throw LivePlaylistError.malformed
        }
        ns = seq
      } else if line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE:") {
        guard tracks.isEmpty, let seq = Int64(tail), seq >= 0, seq < Int64.max - 20000 else {
          throw LivePlaylistError.malformed
        }
        epoch = seq
      } else if line == "#EXT-X-DISCONTINUITY" {
        epoch += 1
        stamp = nil
      } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
        guard let t = Double(tail), t.isFinite, (0.1...120).contains(t) else {
          throw LivePlaylistError.malformed
        }
        duration = t
      } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
        range = String(tail)
      } else if line == "#EXT-X-GAP" {
        gap = true
      } else if line == "#EXT-X-ENDLIST" {
        end = true
      } else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
        guard let date = dateReader.date(from: String(tail)) ?? wholeDate.date(from: String(tail))
        else { throw LivePlaylistError.malformed }
        stamp = date
      } else if line.hasPrefix("#EXTINF:") {
        guard let time = Double(tail.split(separator: ",", maxSplits: 1).first ?? ""),
          time.isFinite, time > 0, time <= 180
        else { throw LivePlaylistError.malformed }
        step = time
        declared = true
      } else if !line.hasPrefix("#") {
        if let attrs = variant {
          v.append(
            .init(
              url: try Self.url(line, base: base, origins: origins), group: attrs["AUDIO"],
              codecs: attrs["CODECS"] ?? ""))
          variant = nil
        } else {
          guard declared, tracks.count < 4096 else { throw LivePlaylistError.malformed }
          let resource = try res(line, range, previous: last)
          tracks.append(
            .init(
              id: ns, media: resource, initial: initial, epoch: epoch, gap: gap, seconds: step,
              date: stamp))
          if let now = stamp { stamp = now.addingTimeInterval(step) }
          last = resource
          ns += 1
          range = nil
          gap = false
          declared = false
        }
      }
    }
    guard v.isEmpty || tracks.isEmpty else { throw LivePlaylistError.malformed }
    if tracks.count > 1 {
      for i in (0..<(tracks.count - 1)).reversed()
      where tracks[i].date == nil && tracks[i].epoch == tracks[i + 1].epoch {
        tracks[i].date = tracks[i + 1].date?.addingTimeInterval(-tracks[i].seconds)
      }
    }
    renditions = alternatives
    variants = v
    external = groups
    media = tracks
    target = duration
    finished = end
  }
  func variant(codec: String) throws -> Variant? {
    if variants.isEmpty { return nil }
    let options = variants
    let prefix: [String]
    switch codec.lowercased() {
    case "avc", "h264": prefix = ["avc1", "avc3"]
    case "hevc", "h265": prefix = ["hvc1", "hev1"]
    case "av1": prefix = ["av01"]
    case "vp9": prefix = ["vp09"]
    default: prefix = []
    }
    guard
      let one = options.first(where: { v in
        v.codecs.isEmpty
          || v.codecs.lowercased().split(separator: ",").contains(where: { c in
            prefix.contains(where: { c.hasPrefix($0) })
          })
      })
    else { throw LivePlaylistError.malformed }
    return one
  }
}
