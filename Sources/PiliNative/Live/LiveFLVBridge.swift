import CLiveRemux
import Foundation

/// Blocks only a private network delegate or the demux worker, never the UI thread.
private final class LiveBytePipe: CertificateSessionDelegate, URLSessionDataDelegate, @unchecked Sendable {
  private let condition = NSCondition()
  private var bytes = MediaBufferFIFO()
  private var capacity: Int
  private var pressure: MediaBufferPressure?
  init(share: Int = 1) {
    capacity = max(64 * 1024, MediaBufferPolicy.current(live: true) / max(1, share))
    super.init()
    pressure = MediaBufferPressure { [weak self] in self?.reduceMemory() }
  }
  private func reduceMemory() {
    condition.lock()
    defer { condition.unlock() }
    capacity = min(capacity, 256 * 1024)
    if !stopped, bytes.count >= capacity * 3 / 4, !suspended, let task {
      suspended = true
      task.suspend()
    }
    condition.broadcast()
  }
  private var ended = false, failed = false, stopped = false, suspended = false
  private var session: URLSession?, task: URLSessionDataTask?
  private var producer: Task<Void, Never>?, playlist: LiveHLSFeed?,
    playlistIssue: LivePlaylistError?
  private let payloadQueue = DispatchQueue(
    label: "pilinative.live.playlist.input", qos: .userInitiated)
  var playlistFailure: LivePlaylistError? {
    condition.lock()
    defer { condition.unlock() }
    return playlistIssue
  }
  private var refusal: Int?
  var rejected: Int? {
    condition.lock()
    defer { condition.unlock() }
    return refusal
  }
  func start(_ source: LiveHLSFeed) {
    condition.lock()
    playlist = source
    condition.unlock()
    let job = Task { [weak self] in
      guard let self else { return }
      do {
        try await source.run { [weak self] d in
          guard let self else { throw CancellationError() }
          try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.payloadQueue.async {
              if self.append(d, from: nil) {
                cont.resume()
              } else {
                cont.resume(throwing: CancellationError())
              }
            }
          }
        }
        self.finishPlaylist(nil)
      } catch { self.finishPlaylist(error) }
    }
    condition.lock()
    let cancel = stopped
    producer = job
    condition.unlock()
    if cancel { job.cancel() }
  }
  private func finishPlaylist(_ error: Error?) {
    condition.lock()
    ended = true
    failed = error != nil
    if let issue = error as? LivePlaylistError {
      playlistIssue = issue
      if case .discontinuity = issue { failed = false }
    }
    condition.broadcast()
    condition.unlock()
  }
  func start(_ url: URL, room: Int64) {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.httpShouldSetCookies = false
    cfg.httpCookieStorage = nil
    cfg.urlCredentialStorage = nil
    cfg.urlCache = nil
    cfg.timeoutIntervalForRequest = 18
    cfg.timeoutIntervalForResource = 7 * 24 * 3600
    let q = OperationQueue()
    q.maxConcurrentOperationCount = 1
    q.qualityOfService = .userInitiated
    let s = URLSession(configuration: cfg, delegate: self, delegateQueue: q)
    var req = URLRequest(url: url)
    req.httpShouldHandleCookies = false
    req.setValue("https://live.bilibili.com/" + String(room), forHTTPHeaderField: "Referer")
    req.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Safari/604.1",
      forHTTPHeaderField: "User-Agent")
    let t = s.dataTask(with: req)
    condition.lock()
    guard !stopped else {
      condition.unlock()
      s.invalidateAndCancel()
      return
    }
    session = s
    task = t
    condition.unlock()
    t.resume()
  }
  var isStopped: Bool {
    condition.lock()
    defer { condition.unlock() }
    return stopped
  }
  func stop() {
    condition.lock()
    stopped = true
    bytes.clear()
    let s = session
    let source = playlist
    let work = producer
    playlist = nil
    producer = nil
    session = nil
    task = nil
    condition.broadcast()
    condition.unlock()
    s?.invalidateAndCancel()
    source?.close()
    work?.cancel()
  }
  func take(_ dst: UnsafeMutablePointer<UInt8>, _ length: Int) -> Int32 {
    condition.lock()
    defer { condition.unlock() }
    while bytes.count == 0 && !ended && !stopped { condition.wait() }
    if stopped { return -1 }
    if bytes.count == 0 { return failed ? -1 : 0 }
    let n = bytes.take(dst, length: length)
    if suspended && bytes.count < capacity / 3 {
      suspended = false
      task?.resume()
    }
    condition.broadcast()
    return Int32(n)
  }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    if let http = response as? HTTPURLResponse, LiveAccessRefused.statuses.contains(http.statusCode)
    {
      condition.lock()
      refusal = http.statusCode
      condition.unlock()
    }
    guard let http = response as? HTTPURLResponse, http.statusCode == 200, !isStopped else {
      completionHandler(.cancel)
      return
    }
    completionHandler(.allow)
  }
  override func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let url = request.url, url.scheme == "https", url.host != nil, url.user == nil,
      url.password == nil
    else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    _ = append(data, from: dataTask)
  }
  private func append(_ data: Data, from task: URLSessionDataTask?) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    data.withUnsafeBytes { b in
      guard let src = b.baseAddress else { return }
      var pos = 0
      while pos < b.count && !stopped {
        while bytes.count >= capacity && !stopped { condition.wait() }
        if stopped { return }
        pos += bytes.append(src.advanced(by: pos), length: b.count - pos, limit: capacity)
        condition.broadcast()
        if let dataTask = task, bytes.count >= capacity * 3 / 4 && !suspended {
          suspended = true
          dataTask.suspend()
        }
      }
    }
    return !stopped
  }
  override func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    condition.lock()
    ended = true
    failed = error != nil
    condition.broadcast()
    condition.unlock()
    session.finishTasksAndInvalidate()
  }
}

final class LiveFLVBridge: @unchecked Sendable {
  private final class Lifetime: @unchecked Sendable {
    let folder: URL
    private let lock = NSLock()
    private var stopped = false, ended = false, failure: String?
    init() throws {
      folder = FileManager.default.temporaryDirectory.appendingPathComponent(
        "pili-live-" + UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }
    func outcome() -> (Bool, String?) {
      lock.lock()
      defer { lock.unlock() }
      return (ended, failure)
    }
    func finish(_ problem: String?) {
      lock.lock()
      ended = true
      failure = problem
      let release = stopped
      lock.unlock()
      if release { try? FileManager.default.removeItem(at: folder) }
    }
    func stop() {
      lock.lock()
      if stopped {
        lock.unlock()
        return
      }
      stopped = true
      let release = ended
      lock.unlock()
      if release { try? FileManager.default.removeItem(at: folder) }
    }
  }
  private let timing:LiveTimingSource
  private let pipe: LiveBytePipe, secondary: LiveBytePipe?, state: Lifetime, server: LiveFileServer
  init(
    url: URL, room: Int64, route: NativeVideoRoute = .direct, codec: Int32 = 0,
    playlist: LiveHLSFeed? = nil
  ) throws {
    let secondary = playlist?.audio.map { _ in LiveBytePipe(share: 2) }
    self.secondary = secondary
    self.pipe = LiveBytePipe(share: secondary == nil ? 1 : 2)
    let state = try Lifetime()
    self.state = state
    timing=LiveTimingSource(folder:state.folder)
    self.server = LiveFileServer(state.folder)
    let pipe = self.pipe
    if let alt = playlist?.audio { secondary?.start(alt) }
    if let playlist { pipe.start(playlist) } else { pipe.start(url, room: room) }
    DispatchQueue.global(qos: .userInitiated).async {
      var error = [CChar](repeating: 0, count: 192)
      let code = state.folder.path.withCString { name in
        let context = Unmanaged.passUnretained(pipe).toOpaque()
        let read:
          @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int32) -> Int32 =
            { ctx, dst, n in
              guard let ctx, let dst, n > 0 else { return -1 }
              return Unmanaged<LiveBytePipe>.fromOpaque(ctx).takeUnretainedValue().take(dst, Int(n))
            }
        let cancel: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { ctx in
          guard let ctx else { return 1 }
          return Unmanaged<LiveBytePipe>.fromOpaque(ctx).takeUnretainedValue().isStopped ? 1 : 0
        }
        if route == .direct && playlist == nil { return pl_live_remux(context, read, cancel, name, &error, 192) }
        let mode:Int32 = route == .direct ? 2 : route == .copied ? 1 : 0
        var stats = PLLiveVideoStats()
        let maxPixels = Int32(
          min(
            UInt64(8192 * 4608),
            max(UInt64(1920 * 1080), ProcessInfo.processInfo.physicalMemory / 144)))
        if let other = secondary, let audio = playlist?.audio {
          return pl_live_decode_pair(
            context, Unmanaged.passUnretained(other).toOpaque(), read, cancel,
            audio.demux, playlist?.dateDelta ?? Int64.min, audio.origin90 ?? -1, name,
            playlist?.demux ?? 1,
            mode, codec, maxPixels, &stats, &error, 192)
        }
        return pl_live_decode_stream(
          context, read, cancel, name, playlist?.demux ?? 0, mode, codec,
          maxPixels, &stats, &error, 192)
      }
      state.finish(code == 0 ? nil : String(cString: error))
      pipe.stop()
      secondary?.stop()
    }
  }
  func playable() async throws -> URL {
    try await withTaskCancellationHandler {
      let url = try await server.start()
      let local = state.folder.appendingPathComponent("index.m3u8")
      let clock = ContinuousClock()
      let end = clock.now.advanced(by: .seconds(22))
      while clock.now < end {
        try Task.checkCancellation()
        if let text = try? String(contentsOf: local, encoding: .utf8), text.contains("#EXTINF:") {
          timing.open(url)
          return url
        }
        if let failure = playlistFailure { throw failure }
        if let code = pipe.rejected { throw LiveAccessRefused(code: code) }
        let outcome = state.outcome()
        if outcome.0 { throw ServiceError(outcome.1 == nil ? "直播流已结束" : "无法读取这条 FLV 线路") }
        try await Task.sleep(for: .milliseconds(120))
      }
      throw ServiceError("直播线路未及时返回可播放的分片")
    } onCancel: {
      self.stop()
    }
  }
  var playlistFailure: LivePlaylistError? { pipe.playlistFailure ?? secondary?.playlistFailure }
  var ended: Bool { state.outcome().0 }
  func stop() {
    timing.stop()
    pipe.stop()
    secondary?.stop()
    server.stop()
    state.stop()
  }
  deinit { stop() }
}
