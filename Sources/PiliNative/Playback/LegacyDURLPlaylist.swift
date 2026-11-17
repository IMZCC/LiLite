import Foundation

/// A single VOD timeline with fresh initialization data at each independently encoded part.
enum LegacyDURLPlaylist {
  struct Rendition {
    let base: URL, playlist: Data, duration: Double, bandwidth: Int
  }
  static func duration(hint: Double?, measured: Double) -> Double {
    guard let hint, hint.isFinite, hint > 0, abs(hint - measured) <= 0.5 else { return measured }
    return hint
  }
  private struct Segment { let map: String, url: String; var duration: Double }
  static func media(_ parts: [Rendition?], durations: [Double]) throws -> Data {
    guard !parts.isEmpty, parts.count == durations.count else { throw LocalIndexIssue.invalid }
    var body = [String](), longest = 1.0
    for (n, entry) in parts.enumerated() {
      guard durations[n].isFinite, durations[n] > 0 else { throw LocalIndexIssue.invalid }
      if n > 0 { body.append("#EXT-X-DISCONTINUITY") }
      guard let entry else {
        longest = max(longest, durations[n])
        body += ["#EXT-X-GAP", "#EXTINF:\(durations[n]),", "gap-\(n).m4s"]
        continue
      }
      guard let text = String(data: entry.playlist, encoding: .utf8) else { throw LocalIndexIssue.invalid }
      var segments = [Segment](), map: String?, pending: Double?
      for line in text.split(whereSeparator: \.isNewline).map(String.init) {
        if line.hasPrefix("#EXTINF:") {
          guard let field = line.dropFirst(8).split(separator: ",").first,
            let duration = Double(field), duration.isFinite, duration > 0 else { throw LocalIndexIssue.invalid }
          pending = duration
        } else if line.hasPrefix("#EXT-X-MAP:URI=\""), let end = line.dropFirst(16).firstIndex(of: "\"") {
          let raw = String(line[line.index(line.startIndex, offsetBy: 16)..<end])
          guard let resolved = URL(string: raw, relativeTo: entry.base)?.absoluteURL else { throw LocalIndexIssue.invalid }
          map = resolved.absoluteString
        } else if !line.hasPrefix("#"), !line.isEmpty {
          guard let resolved = URL(string: line, relativeTo: entry.base)?.absoluteURL, let map, let interval = pending else { throw LocalIndexIssue.invalid }
          segments.append(.init(map: map, url: resolved.absoluteString, duration: interval))
          pending = nil
        }
      }
      guard !segments.isEmpty else { throw LocalIndexIssue.invalid }
      // Encoded audio padding and FLV's reordering lead-in may differ from the granted period
      // length. End each rendition on the same boundary, so later periods never accumulate drift.
      var difference = durations[n] - segments.reduce(0) { $0 + $1.duration }
      while difference < 0, let last = segments.last, last.duration + difference <= 0 {
        difference += last.duration; segments.removeLast()
      }
      guard !segments.isEmpty, segments[segments.count - 1].duration + difference > 0 else { throw LocalIndexIssue.invalid }
      segments[segments.count - 1].duration += difference
      var previous: String?
      for segment in segments {
        if previous != segment.map { body.append("#EXT-X-MAP:URI=\"\(segment.map)\""); previous = segment.map }
        longest = max(longest, segment.duration)
        body += ["#EXTINF:\(segment.duration),", segment.url]
      }
    }
    let header = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-TARGETDURATION:\(Int(ceil(longest)))", "#EXT-X-MEDIA-SEQUENCE:0"]
    return Data((header + body + ["#EXT-X-ENDLIST", ""]).joined(separator: "\n").utf8)
  }
}
