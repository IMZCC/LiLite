import Foundation

protocol LegacyChildPlayback: OfflinePlaybackBridge, PictureTimingSource {
  var decodeRoute: NativeVideoRoute { get }
  var remainingDecoderRoutes: [NativeVideoRoute] { get }
  func legacyRendition(audio: Bool, url: URL) -> LegacyDURLPlaylist.Rendition?
  func cancelDemands()
}
extension DashBridge: LegacyChildPlayback {}

private struct LegacyFLVSegment: LegacySliceResource, @unchecked Sendable {
  let bridge: DashBridge, directory: URL
  func close() { bridge.close(); try? FileManager.default.removeItem(at: directory) }
  func cancelDemands() { bridge.cancelDemands() }
}

/// An indexed FLV remains remote. Only its header and the requested keyframe interval are read.
final class LegacyFLVBridge: LegacyChildPlayback, @unchecked Sendable {
  private let remote: ProgressiveMediaRanges, total: Int64, header: Data, index: LegacyFLVIndex
  private let plan: LegacyDURLPlan, routes: [NativeVideoRoute]?, audioOnly: Bool
  private let directory: URL, pool = LegacySlicePool<LegacyFLVSegment>(), lock = NSLock()
  private var stopped = false, last: DashBridge?, tookAlternatives = false
  private final class Weak { weak var value: DashBridge?; init(_ value: DashBridge) { self.value = value } }
  private var clocks: [Int: Weak] = [:]
  private var relay: LegacyMediaHTTP?
  private init(remote: ProgressiveMediaRanges, total: Int64, header: Data, index: LegacyFLVIndex,
    plan: LegacyDURLPlan, routes: [NativeVideoRoute]?, audioOnly: Bool) {
    self.remote = remote; self.total = total; self.header = header; self.index = index
    self.plan = plan; self.routes = routes; self.audioOnly = audioOnly
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-flv-" + UUID().uuidString, isDirectory: true)
  }
  static func open(_ url: URL, total: Int64, plan: LegacyDURLPlan, hint: Double?,
    routes: [NativeVideoRoute]?, audioOnly: Bool) async throws -> (bridge: LegacyFLVBridge, url: URL) {
    let source = try ProgressiveMediaRanges(url: url, reference: plan.reference)
    let (index, prefix) = try await LegacyFLVIndex.open(total: total, hint: hint) { a, n in
      let bytes = try await source.read(a, n)
      guard bytes.total == total else { throw LocalIndexIssue.invalid }; return bytes.data
    }
    guard !audioOnly || index.audio else { throw ServiceError("此视频没有可用的音轨") }
    let result = LegacyFLVBridge(remote: source, total: total, header: prefix, index: index, plan: plan, routes: routes, audioOnly: audioOnly)
    do {
      try FileManager.default.createDirectory(at: result.directory, withIntermediateDirectories: true)
      let relay = LegacyMediaHTTP { [weak result] path in
        guard let result else { throw CancellationError() }
        return try await result.serve(path)
      }
      result.relay = relay
      let local = try await relay.start(); try await result.authorize()
      return (result, local)
    } catch { result.close(); throw error }
  }
  private func authorize() async throws {
    try Task.checkCancellation()
    guard !lock.withLock({ stopped }) else { throw CancellationError() }
    guard (try await AccountJar.shared.current(.role(.video))?.id ?? "") == plan.owner else { throw ServiceError("视频账号已切换") }
  }
  var decodeRoute: NativeVideoRoute { lock.withLock { last?.decodeRoute ?? .direct } }
  var remainingDecoderRoutes: [NativeVideoRoute] { lock.withLock { last?.remainingDecoderRoutes ?? [.copied, .software] } }
  func takeRemainingDecoderRoutes() -> [NativeVideoRoute] {
    lock.withLock { if tookAlternatives { return [] }; tookAlternatives = true; return last?.remainingDecoderRoutes ?? [.copied, .software] }
  }
  private func playlist() -> Data {
    index.playlist()
  }
  func legacyRendition(audio: Bool, url: URL) -> LegacyDURLPlaylist.Rendition? {
    guard !audio || index.audio else { return nil }
    return .init(base: url.deletingLastPathComponent().appendingPathComponent((audio ? "a" : "v") + "/index.m3u8"),
      playlist: playlist(), duration: index.duration, bandwidth: Int(min(1_000_000_000, Double(total) * 8 / index.duration)))
  }
  private func segment(_ n: Int) async throws -> LegacyFLVSegment {
    try await authorize()
    guard index.parts.indices.contains(n) else { throw LocalIndexIssue.invalid }
    return try await pool.get(n) { [self] in
      try await authorize()
      let part = index.parts[n], folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      do {
        let input = folder.appendingPathComponent("source.flv"), output = folder.appendingPathComponent("movie.mp4")
        try header.write(to: input, options: .atomic)
        let file = try FileHandle(forWritingTo: input)
        do {
          try file.seekToEnd(); var at = part.offset
          while at < part.end {
            try await authorize()
            let bytes = try await remote.read(at, Int(min(512 * 1024, part.end - at)))
            guard bytes.total == total else { throw LocalIndexIssue.invalid }
            try file.write(contentsOf: bytes.data); at += Int64(bytes.data.count)
          }
          try file.close()
        } catch { try? file.close(); throw error }
        try await LegacyMovieRemux.convert(input, to: output, beginning: part.start,
          cancelled: { self.lock.withLock { self.stopped } })
        let task = Task.detached(priority: .userInitiated) { try LocalMovieFragments.open(LocalMediaFile(output)) }
        let (v, a) = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try await authorize()
        let source = OfflineDecoderSource(video: v, audio: a, quality: plan.body.quality ?? 0, owner: plan.owner, volume: plan.body.volume)
        let next = try await ProgressiveDecoderBridge.start(source, routes: routes, audioOnly: audioOnly)
        lock.withLock { last = next.bridge; clocks[n] = Weak(next.bridge); clocks = clocks.filter { $0.value.value != nil } }
        try? FileManager.default.removeItem(at: input)
        return .init(bridge: next.bridge, directory: folder)
      } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
  }
  private func serve(_ path: String) async throws -> LegacyMediaHTTP.Body {
    try await authorize()
    let parts = path.split(separator: "/")
    guard parts.count == 2, parts[0] == "v" || parts[0] == "a" else { throw LocalIndexIssue.invalid }
    if parts[1] == "index.m3u8" { return (playlist(), "application/vnd.apple.mpegurl") }
    guard let requested = DecoderFragment.request(String(parts[1])), index.parts.indices.contains(requested.index) else { throw LocalIndexIssue.invalid }
    let child = try await segment(requested.index), audio = parts[0] == "a"
    defer { Task { await pool.release(requested.index) } }
    let initial = try await child.bridge.legacyPiece(audio: audio, initial: true)
    let bytes: Data
    if requested.initial { bytes = initial }
    else {
      bytes = try LegacyFragmentTime.shifted(await child.bridge.legacyPiece(audio: audio, initial: false), initial: initial, seconds: index.parts[requested.index].start)
    }
    try await authorize()
    return (bytes, audio ? "audio/mp4" : "video/mp4")
  }
  func seek(to seconds: Double) { guard let n = index.part(at: seconds) else { return }; relay?.cancelSlices(near: n); Task { await pool.seek(n) } }
  func cancelDemands() { relay?.cancelRequests(); Task { await pool.cancel() } }
  var clockFPS: Double? { index.fps }
  func clockIndex(at time: Double) -> Int? {
    guard let n = index.part(at: time) else { return nil }
    let local = lock.withLock { clocks[n]?.value?.clockIndex(at: time - index.parts[n].start) } ?? 0
    return (n << 20) | local
  }
  func clockPart(_ requested: Int) async throws -> ClockAudioPart? {
    let n = requested >> 20, part = try await segment(n)
    defer { Task { await pool.release(n) } }
    guard let first = try await part.bridge.clockPart(requested & ((1 << 20) - 1)) else { return nil }
    return .init(index: requested, start: index.parts[n].start + first.start, pcm: first.pcm)
  }
  func close() {
    lock.withLock { stopped = true }; remote.close(); relay?.close(); relay = nil
    Task { await pool.stop() }
  }
  deinit { try? FileManager.default.removeItem(at: directory) }
}
