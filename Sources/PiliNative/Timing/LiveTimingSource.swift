import Foundation

/// Only reads files from this playback's private rolling muxer, never provider URLs. Program date
/// maps the *current* AVKit live timeline onto media sequence after the old segments disappear.
final class LiveTimingSource: DatedPictureTimingSource, @unchecked Sendable {
  struct Slot: Sendable, Equatable { let n: Int, date: Double, duration: Double }
  private let lock = NSLock(), folder: URL
  private var lastUse = 0.0
  private var slots: [Slot] = [], anchor: Double?, mediaOrigin: Double?, closed = false,
    ended = false,
    monitor: Task<Void, Never>?
  var clockFPS: Double? { nil }
  init(folder: URL) { self.folder = folder }
  static func parse(_ text: String) -> ([Slot], Bool)? {
    guard text.utf8.count <= 32 * 1024, text.hasPrefix("#EXTM3U"), !text.contains("#EXT-X-KEY"),
      !text.contains("#EXT-X-DISCONTINUITY"),
      text.contains("#EXT-X-MAP:URI=\"init.mp4\"")
    else { return nil }
    var list = [Slot]()
    var date: Double?
    var duration: Double?
    var seq: Int?
    var end = false
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    for row in text.split(whereSeparator: \.isNewline) {
      if row.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
        seq = Int(row.dropFirst(22))
        continue
      }
      if row.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
        let v = String(row.dropFirst(25))
        date = (formatter.date(from: v) ?? plain.date(from: v))?.timeIntervalSince1970
      } else if row.hasPrefix("#EXTINF:") {
        duration = Double(row.dropFirst(8).prefix(while: { $0 != "," }))
      } else if row == "#EXT-X-ENDLIST" {
        end = true
      } else if !row.hasPrefix("#") {
        guard let n = seq, n >= 0, n < 100_000_000,
          row == Substring(String(format: "part%08d.m4s", n)), let t = date, t.isFinite,
          let d = duration, d > 0, d <= 60, list.count < 12
        else { return nil }
        if let prior = list.last, abs(t - prior.date - prior.duration) > 1 { return nil }
        list.append(.init(n: n, date: t, duration: d))
        date = t + d
        seq = n + 1
        duration = nil
      }
    }
    return list.isEmpty ? nil : (list, end)
  }
  private func bytes(_ name: String, limit: Int) throws -> Data {
    if lock.withLock({ closed }) { throw CancellationError() }
    let f = try FileHandle(forReadingFrom: folder.appendingPathComponent(name))
    defer { try? f.close() }
    let length = try f.seekToEnd()
    guard length > 0, length <= limit else { throw DecoderProblem.size }
    try f.seek(toOffset: 0)
    guard let d = try f.read(upToCount: Int(length)), d.count == length else {
      throw DecoderProblem.unsupported
    }
    return d
  }
  private func scan() {
    guard let data = try? bytes("index.m3u8", limit: 32 * 1024),
      let text = String(data: data, encoding: .utf8), let (rows, last) = Self.parse(text)
    else { return }
    lock.withLock {
      if !closed {
        slots = rows
        ended = last
      }
    }
  }
  func open(_ url: URL) {
    scan()
    let work = Task.detached(priority: .utility) { [weak self] in
      while !Task.isCancelled, self != nil {
        try? await Task.sleep(for: .milliseconds(350))
        if !Task.isCancelled, let self,
          lock.withLock({ ProcessInfo.processInfo.systemUptime - self.lastUse < 3 })
        {
          scan()
        }
      }
    }
    lock.withLock { if closed { work.cancel() } else { monitor = work } }
    PictureTimingRegistry.shared.add(url, source: self)
  }
  func stop() {
    lock.withLock {
      closed = true
      monitor?.cancel()
      monitor = nil
      slots = []
      anchor = nil
    }
  }
  func locate(itemTime: Double, date: Date?) {
    guard itemTime.isFinite, let date else { return }
    let offset = date.timeIntervalSince1970 - itemTime
    guard offset.isFinite else { return }
    lock.withLock {
      if !closed {
        anchor = offset
        lastUse = ProcessInfo.processInfo.systemUptime
      }
    }
  }
  func clockIndex(at time: Double) -> Int? {
    lock.withLock {
      guard !closed, let anchor else { return nil }
      let date = anchor + time
      return slots.first(where: { $0.date <= date && date < $0.date + $0.duration })?.n
    }
  }
  func clockPart(_ n: Int) async throws -> ClockAudioPart? {
    guard (0..<100_000_000).contains(n) else { return nil }
    for _ in 0..<65 {
      try Task.checkCancellation()
      let state = lock.withLock { (closed, anchor, slots, ended) }
      if state.0 { throw CancellationError() }
      guard let anchor = state.1 else { return nil }
      if let s = state.2.first(where: { $0.n == n }) {
        let pre = try bytes("init.mp4", limit: 4 * 1024 * 1024)
        let capacity = 48 * 1024 * 1024
        let previous: Data
        if n > 0 {
          previous =
            (try? bytes(String(format: "part%08d.m4s", n - 1), limit: capacity / 2)) ?? Data()
        } else {
          previous = Data()
        }
        let segment = try bytes(String(format: "part%08d.m4s", n), limit: capacity - previous.count)
        let base = Int64(pre.count)
        let a = base + Int64(previous.count)
        let pcm = try await ClockPCM.decode(
          initial: pre, media: previous + segment, offset: base,
          target: .init(a, a + Int64(segment.count) - 1))
        guard !lock.withLock({ closed }) else { throw CancellationError() }
        // EXT-X-PROGRAM-DATE-TIME timestamps the first media sample. Keep any genuine lead or
        // delay between the video pictures and the selected audio; do not zero each elementary stream.
        guard let video = pcm.videoStart else { return nil }
        let delta = Double(pcm.startSample) / Double(pcm.rate) - video
        guard delta.isFinite, abs(delta) <= 2 else { throw DecoderProblem.unsupported }
        let audio = Double(pcm.startSample) / Double(pcm.rate)
        let proposed = s.date - min(video, audio)
        let origin = lock.withLock {
          if mediaOrigin == nil { mediaOrigin = proposed }
          return mediaOrigin!
        }
        guard abs(proposed - origin) <= 2 else { throw DecoderProblem.unsupported }
        let start = origin - anchor + audio
        return .init(index: n, start: start, pcm: pcm)
      }
      if state.3 || state.2.first.map({ n < $0.n }) == true { return nil }
      try await Task.sleep(for: .milliseconds(150))
    }
    return nil
  }
  deinit { monitor?.cancel() }
}
