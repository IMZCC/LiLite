import Foundation
import Network

/// Each server part keeps its decoder, sample index and cancellation scope. The outer VOD playlist
/// supplies a continuous seek timeline without assuming that adjacent parts use the same codec.
final class LegacyDURLPlayback: PictureTimingSource, @unchecked Sendable {
  private struct Child {
    let bridge: any LegacyChildPlayback, url: URL, video: LegacyDURLPlaylist.Rendition
    let audio: LegacyDURLPlaylist.Rendition?
    let start: Double, duration: Double
  }
  private let plan: LegacyDURLPlan?
  private let offline: (lease: OfflinePlaybackFiles, components: [String], owner: String, quality: Int, volume: AudioMeasurements?, durations: [Double]?)?
  private let routes: [NativeVideoRoute]?
  private let audioOnly: Bool
  private let lock = NSLock(), transport = RangeTransport()
  private var stopped = false, children: [Child] = []
  private let directory: URL
  private let queue = DispatchQueue(label: "pilinative.legacy-vod")
  private let token = UUID().uuidString
  private var listener: NWListener?, waiting = true
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var jobs: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var lists: [String: Data] = [:]
  init(_ plan: LegacyDURLPlan, routes: [NativeVideoRoute]? = nil, audioOnly: Bool = false) {
    self.plan = plan; self.routes = routes; offline = nil
    self.audioOnly = audioOnly
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-vod-" + UUID().uuidString, isDirectory: true)
  }
  init(offline lease: OfflinePlaybackFiles, row: OfflineVideo, routes: [NativeVideoRoute]?) throws {
    guard row.legacyMedia, let owner = row.cacheOwner else { throw ServiceError("缓存片段清单无效") }
    plan = nil; self.routes = routes
    audioOnly = false
    offline = (lease, row.components, owner, row.quality ?? 0, row.audioMeasurements, row.legacyDurations)
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-vod-" + UUID().uuidString, isDirectory: true)
  }
  private func authorize() async throws {
    try Task.checkCancellation()
    guard !lock.withLock({ stopped }) else { throw CancellationError() }
    if let offline {
      guard (try await AccountJar.shared.localOwner(.role(.video)) ?? "") == offline.owner else { throw ServiceError("缓存账号已切换") }
    } else if let plan {
      guard (try await AccountJar.shared.current(.role(.video))?.id ?? "") == plan.owner else { throw ServiceError("视频账号已切换") }
    } else { throw CancellationError() }
  }
  var duration: Double { lock.withLock { children.last.map { $0.start + $0.duration } ?? 0 } }
  var decodeRoute: NativeVideoRoute { lock.withLock { children.first?.bridge.decodeRoute ?? .direct } }
  var remainingDecoderRoutes: [NativeVideoRoute] {
    lock.withLock {
      guard let first = children.first else { return [] }
      return first.bridge.remainingDecoderRoutes.filter { r in children.allSatisfy { $0.bridge.remainingDecoderRoutes.contains(r) } }
    }
  }
  private var tookAlternatives = false
  func takeRemainingDecoderRoutes() -> [NativeVideoRoute] {
    let result = remainingDecoderRoutes
    return lock.withLock { if tookAlternatives { return [] }; tookAlternatives = true; return result }
  }
  func start() async throws -> URL {
    do {
      return try await withTaskCancellationHandler {
        try await authorize()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let remote = try plan?.body.parts ?? []
        let count = offline?.components.count ?? remote.count
        for n in 0..<count {
          try await authorize()
          let opened: (bridge: any LegacyChildPlayback, url: URL)
          if let offline {
            guard let file = offline.lease.files[offline.components[n]] else { throw ServiceError("缓存片段缺失") }
            let task = Task.detached(priority: .userInitiated) { try LocalMovieFragments.open(LocalMediaFile(file)) }
            let (v, a) = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            opened = try await ProgressiveDecoderBridge.start(.init(video: v, audio: a, quality: offline.quality,
              owner: offline.owner, lease: offline.lease, volume: offline.volume), routes: routes)
          } else { opened = try await open(remote[n], index: n) }
          do { try await authorize() } catch { opened.bridge.close(); throw error }
          guard let video = opened.bridge.legacyRendition(audio: audioOnly, url: opened.url) else { opened.bridge.close(); throw LocalIndexIssue.invalid }
          let audio = opened.bridge.legacyRendition(audio: true, url: opened.url)
          let hint: Double?
          if let offline { hint = offline.durations.flatMap { $0.indices.contains(n) ? $0[n] : nil } }
          else { hint = remote[n].length.map { $0 / 1000 } }
          let duration = LegacyDURLPlaylist.duration(hint: hint, measured: video.duration)
          let accepted = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            let start = children.last.map { $0.start + $0.duration } ?? 0
            children.append(.init(bridge: opened.bridge, url: opened.url, video: video, audio: audio, start: start, duration: duration))
            return true
          }
          guard accepted else { opened.bridge.close(); throw CancellationError() }
        }
        let active = lock.withLock { children }
        let durations = active.map(\.duration)
        let sound = active.contains { $0.audio != nil }
        lists["v.m3u8"] = try LegacyDURLPlaylist.media(active.map(\.video), durations: durations)
        if sound { lists["a.m3u8"] = try LegacyDURLPlaylist.media(active.map(\.audio), durations: durations) }
        let rate = active.map { $0.video.bandwidth + ($0.audio?.bandwidth ?? 0) }.max() ?? 1
        var master = ["#EXTM3U", "#EXT-X-VERSION:7"]
        if sound { master += ["#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"sound\",NAME=\"音频\",DEFAULT=YES,AUTOSELECT=YES,URI=\"a.m3u8\""] }
        master += ["#EXT-X-STREAM-INF:BANDWIDTH=\(max(1, rate))" + (sound ? ",AUDIO=\"sound\"" : ""), "v.m3u8", ""]
        lists["master.m3u8"] = Data(master.joined(separator: "\n").utf8)
        try await authorize()
        let url = try await listen(playlist: audioOnly ? "a.m3u8" : "master.m3u8")
        if sound { PictureTimingRegistry.shared.add(url, source: self) }
        return url
      } onCancel: { self.close() }
    } catch { close(); throw error }
  }
  private func open(_ part: LegacyDURLBody.Part, index: Int) async throws -> (bridge: any LegacyChildPlayback, url: URL) {
    guard let plan else { throw LocalIndexIssue.invalid }
    var failure: Error = URLError(.cannotConnectToHost)
    for url in part.routes {
      try await authorize()
      do {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue(plan.reference.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=0-15", forHTTPHeaderField: "Range")
        let prefix = try await transport.response(request, limit: 16)
        try await authorize()
        if prefix.data.starts(with: [0x46, 0x4c, 0x56]) {
          do {
            return try await LegacyFLVBridge.open(url, total: prefix.total, plan: plan, hint: part.length.map { $0 / 1000 }, routes: routes, audioOnly: audioOnly)
          } catch LegacyFLVIndex.Issue.unavailable { }
          return try await flv(url, total: prefix.total, index: index)
        }
        return try await ProgressiveDecoderBridge.open(url: url, reference: plan.reference,
          quality: plan.body.quality ?? 0, owner: plan.owner, volume: plan.body.volume, routes: routes, audioOnly: audioOnly)
      } catch {
        try await authorize()
        // A refused authorization is not a broken CDN mirror.
        if let status = error as? RangeHTTPStatus, [401, 403, 412, 429].contains(status.code) { throw error }
        failure = error
      }
    }
    throw failure
  }
  private func flv(_ url: URL, total: Int64, index: Int) async throws -> (bridge: DashBridge, url: URL) {
    guard let plan else { throw LocalIndexIssue.invalid }
    guard total >= 16, total < Int64.max / 3 else { throw LocalIndexIssue.invalid }
    let capacity = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    if let capacity, capacity < total * 2 + 64 * 1024 * 1024 { throw ServiceError("设备空间不足，无法准备此视频") }
    let input = directory.appendingPathComponent("\(index).flv"), output = directory.appendingPathComponent("\(index).mp4")
    try Data().write(to: input, options: .atomic)
    let file = try FileHandle(forWritingTo: input)
    do {
      var offset: Int64 = 0
      while offset < total {
        try await authorize()
        let size = Int(min(512 * 1024, total - offset))
        var req = URLRequest(url: url)
        req.httpShouldHandleCookies = false
        req.setValue(plan.reference.absoluteString, forHTTPHeaderField: "Referer")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.setValue("bytes=\(offset)-\(offset + Int64(size) - 1)", forHTTPHeaderField: "Range")
        let response = try await transport.response(req, limit: size)
        guard response.total == total else { throw LocalIndexIssue.invalid }
        try await authorize()
        try file.write(contentsOf: response.data)
        offset += Int64(response.data.count)
      }
      try file.close()
    } catch { try? file.close(); throw error }
    try await LegacyMovieRemux.convert(input, to: output, cancelled: { self.lock.withLock { self.stopped } })
    let task = Task.detached(priority: .userInitiated) { try LocalMovieFragments.open(LocalMediaFile(output)) }
    let (v, a) = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    try await authorize()
    try? FileManager.default.removeItem(at: input)
    return try await ProgressiveDecoderBridge.start(.init(video: v, audio: a, quality: plan.body.quality ?? 0,
      owner: plan.owner, volume: plan.body.volume), routes: routes, audioOnly: audioOnly)
  }
  func seek(to time: Double) {
    guard time.isFinite, time >= 0 else { return }
    let active = lock.withLock { children }
    let n = active.lastIndex { time >= $0.start } ?? 0
    for (i, child) in active.enumerated() {
      if i == n { child.bridge.seek(to: max(0, time - child.start)) } else { child.bridge.cancelDemands() }
    }
  }
  var clockFPS: Double? { lock.withLock { children.first?.bridge.clockFPS } }
  func clockIndex(at time: Double) -> Int? {
    let active = lock.withLock { children }
    guard time.isFinite, time >= 0, let n = active.lastIndex(where: { time >= $0.start }),
      let part = active[n].bridge.clockIndex(at: time - active[n].start), part < 1 << 48 else { return nil }
    return (n << 48) | part
  }
  func clockPart(_ index: Int) async throws -> ClockAudioPart? {
    try await authorize()
    let active = lock.withLock { children }, n = index >> 48
    guard active.indices.contains(n), let part = try await active[n].bridge.clockPart(index & ((1 << 48) - 1)) else { return nil }
    try await authorize()
    return .init(index: index, start: active[n].start + part.start, pcm: part.pcm)
  }
  func close() {
    let active = lock.withLock { () -> [Child] in stopped = true; return children }
    active.forEach { $0.bridge.close() }
    transport.close()
    queue.async {
      self.listener?.cancel(); self.listener = nil
      self.jobs.values.forEach { $0.cancel() }; self.jobs.removeAll()
      self.connections.values.forEach { $0.cancel() }; self.connections.removeAll()
    }
  }
  deinit { try? FileManager.default.removeItem(at: directory) }
  private func listen(playlist: String) async throws -> URL {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let server = try NWListener(using: parameters)
    listener = server
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      server.stateUpdateHandler = { state in
        guard self.waiting else { return }
        switch state {
        case .ready:
          self.waiting = false
          if let port = server.port { continuation.resume(returning: port.rawValue) }
          else { continuation.resume(throwing: URLError(.cannotConnectToHost)) }
        case .failed(let error): self.waiting = false; continuation.resume(throwing: error)
        case .cancelled: self.waiting = false; continuation.resume(throwing: CancellationError())
        default: break
        }
      }
      server.newConnectionHandler = { [weak self] connection in
        guard let self else { connection.cancel(); return }
        let key = ObjectIdentifier(connection)
        self.connections[key] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
          guard let connection else { return }
          switch state {
          case .failed, .cancelled:
            self?.jobs.removeValue(forKey: ObjectIdentifier(connection))?.cancel()
            self?.connections.removeValue(forKey: ObjectIdentifier(connection))
          default: break
          }
        }
        connection.start(queue: self.queue)
        self.receive(connection, accumulated: Data())
      }
      server.start(queue: queue)
    }
    try await authorize()
    return URL(string: "http://127.0.0.1:\(port)/\(token)/\(playlist)")!
  }
  private func receive(_ connection: NWConnection, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] bytes, _, done, error in
      guard let self, let bytes, !bytes.isEmpty, error == nil else { connection.cancel(); return }
      let input = accumulated + bytes
      guard input.count <= 8192 else { connection.cancel(); return }
      guard let text = String(data: input, encoding: .utf8), text.contains("\r\n\r\n") else {
        if done { connection.cancel() } else { self.receive(connection, accumulated: input) }
        return
      }
      let request = text.components(separatedBy: "\r\n")[0].split(separator: " ")
      guard request.count == 3, ["GET", "HEAD"].contains(String(request[0])),
        request[1].hasPrefix("/\(self.token)/") else { connection.cancel(); return }
      let name = String(request[1].dropFirst(self.token.count + 2))
      guard let body = self.lists[name] else { connection.cancel(); return }
      let head = request[0] == "HEAD", key = ObjectIdentifier(connection)
      self.jobs[key] = Task {
        do {
          try await self.authorize()
          let header = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
          let response = Data(header.utf8) + (head ? Data() : body)
          self.queue.async { connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() }) }
        } catch { connection.cancel() }
      }
    }
  }
}
