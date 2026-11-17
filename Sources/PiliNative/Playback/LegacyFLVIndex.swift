import CLiveRemux
import Foundation

struct LegacyFLVIndex {
  enum Issue: Error { case unavailable }
  struct Part { let offset: Int64, end: Int64, start: Double, duration: Double }
  let parts: [Part], prefixLength: Int64, duration: Double, audio: Bool, fps: Double?
  static func open(total: Int64, hint: Double?, read: @Sendable (Int64, Int) async throws -> Data) async throws -> (index: Self, header: Data) {
    var prefix = Data(), wanted = min(total, 64 * 1024)
    let maximum = min(total, 4 * 1024 * 1024)
    func append(through end: Int64) async throws {
      while Int64(prefix.count) < end {
        try Task.checkCancellation()
        let size = Int(min(512 * 1024, end - Int64(prefix.count)))
        let bytes = try await read(Int64(prefix.count), size)
        guard bytes.count == size else { throw LocalIndexIssue.invalid }; prefix.append(bytes)
      }
    }
    while true {
      try await append(through: wanted)
      do {
        let index = try Self(prefix: prefix, total: total, hint: hint)
        try await append(through: index.prefixLength)
        return (index, Data(prefix.prefix(Int(index.prefixLength))))
      } catch Issue.unavailable {
        guard wanted < maximum else { throw Issue.unavailable }
        wanted = min(maximum, wanted * 2)
      }
    }
  }
  init(prefix: Data, total: Int64, hint: Double?) throws {
    var raw = PLVODIndex()
    let status = prefix.withUnsafeBytes { bytes in
      pl_vod_flv_index(bytes.bindMemory(to: UInt8.self).baseAddress, Int32(bytes.count), total, &raw)
    }
    defer { pl_vod_free_index(&raw) }
    guard status == 0, raw.count >= 2, raw.count <= 131072, let times = raw.times, let offsets = raw.positions else { throw Issue.unavailable }
    duration = LegacyDURLPlaylist.duration(hint: hint, measured: raw.duration)
    audio = raw.audio != 0
    fps = raw.fps.isFinite && raw.fps > 0 ? raw.fps : nil
    var entries = [Part]()
    for n in 0..<Int(raw.count) {
      let start = n == 0 ? 0 : times[n], end = n + 1 < Int(raw.count) ? times[n + 1] : duration
      guard start.isFinite, end > start, end - start <= 90,
        offsets[n] >= 13, offsets[n] < total else { throw Issue.unavailable }
      let last = n + 1 < Int(raw.count) ? offsets[n + 1] : total
      guard last > offsets[n], last - offsets[n] <= 48 * 1024 * 1024 else { throw Issue.unavailable }
      entries.append(.init(offset: offsets[n], end: last, start: start, duration: end - start))
    }
    parts = entries; prefixLength = offsets[0]
  }
  func part(at time: Double) -> Int? {
    guard time.isFinite, time >= 0, time < duration else { return nil }
    return parts.lastIndex { time >= $0.start }
  }
  func playlist() -> Data {
    var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-TARGETDURATION:\(Int(ceil(parts.map(\.duration).max() ?? 1)))", "#EXT-X-MEDIA-SEQUENCE:0"]
    for (n, part) in parts.enumerated() { lines += ["#EXT-X-MAP:URI=\"init-\(n).mp4\"", "#EXTINF:\(part.duration),", "\(n).m4s"] }
    lines += ["#EXT-X-ENDLIST", ""]; return Data(lines.joined(separator: "\n").utf8)
  }
}
