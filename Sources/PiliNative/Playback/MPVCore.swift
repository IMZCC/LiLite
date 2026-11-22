import CMPV
import Foundation

struct MPVSnapshot {
  var generation = UUID()
  var position = 0.0
  var positionHost = ProcessInfo.processInfo.systemUptime
  var duration = 0.0
  var speed = 1.0
  var paused = true
  var buffering = false
  var cacheEnd = 0.0
  var width: Int64 = 0
  var height: Int64 = 0
  var loaded = false
  var ended = false
  var failure: String?
}

/// All client commands and event reads run here. Rendering has its own GL queue.
/// The mailbox holds one snapshot, so a busy main thread never accumulates progress callbacks.
final class MPVCore: @unchecked Sendable {
  private var handle: OpaquePointer?
  private let initialization = DispatchGroup()
  private let queue = DispatchQueue(label: "pili.mpv.client", qos: .userInitiated)
  private let mailboxLock = NSLock()
  private var mailbox: MPVSnapshot?
  private var deliveryQueued = false
  private var receiver: ((MPVSnapshot) -> Void)?
  private var snapshot = MPVSnapshot()
  private var stopped = false
  private var startupError: String?
  private var lastPublish = -Double.infinity
  private var entryID: Int64 = -1
  private var needsExternalAudio = false
  private var seeks: [(Bool) -> Void] = []
  private var seekID = UUID()
  private var seekTarget: Double?

  init() {
    queue.async(group: initialization) { [self] in initialize() }
  }
  /// Only the renderer needs the handle outside the client queue. Its first draw can
  /// wait here without blocking navigation or delaying commands already queued by load().
  func renderHandle() -> OpaquePointer? {
    initialization.wait()
    return handle
  }
  private func initialize() {
    handle = mpv_create()
    guard let handle else { startupError = "无法创建播放器"; return }
    let options = [
      "config": "no", "terminal": "no", "input-default-bindings": "no",
      "input-vo-keyboard": "no", "osc": "no", "idle": "yes", "keep-open": "yes",
      "vo": "libmpv", "ao": "audiounit", "hwdec": "videotoolbox",
      "keepaspect": "yes",
      // 10-bit HEVC/AV1 (HDR, 杜比视界, HDR Vivid) decodes to P010 by default. The iOS GLES
      // interop has no 16-bit normalized textures, so P010 planes were sampled as the wrong
      // type and showed red/green garbage. VideoToolbox converts to 8-bit NV12 in hardware;
      // mpv still tone-maps from the stream's PQ/HLG metadata.
      "hwdec-image-format": "nv12",
      "hwdec-codecs": "all", "audio-pitch-correction": "yes", "cache": "yes",
      "tls-verify": "yes", "network-timeout": "20", "video-sync": "audio",
      "sub-auto": "no", "audio-file-auto": "no", "ytdl": "no",
      "screenshot-format": "png", "screenshot-png-compression": "1",
    ]
    for (key, value) in options { mpv_set_option_string(handle, key, value) }
    let result = mpv_initialize(handle)
    if result < 0 { startupError = Self.message(result); return }
    for property in ["time-pos", "duration", "speed", "demuxer-cache-time"] {
      mpv_observe_property(handle, 0, property, MPV_FORMAT_DOUBLE)
    }
    for property in ["pause", "paused-for-cache", "eof-reached"] {
      mpv_observe_property(handle, 0, property, MPV_FORMAT_FLAG)
    }
    mpv_observe_property(handle, 0, "video-out-params", MPV_FORMAT_NODE)
    queue.async { [weak self] in self?.poll() }
  }
  static func message(_ code: Int32) -> String { String(cString: mpv_error_string(code)) }
  func observe(_ receiver: @escaping (MPVSnapshot) -> Void) {
    mailboxLock.lock()
    self.receiver = receiver
    mailboxLock.unlock()
  }
  func set(_ name: String, _ value: String) {
    queue.async { [weak self] in
      guard let self, !self.stopped, let handle = self.handle else { return }
      mpv_set_property_string(handle, name, value)
    }
  }
  func renderFailed(_ code: Int32) {
    queue.async { [weak self] in
      guard let self, !self.stopped else { return }
      self.snapshot.failure = "视频渲染初始化失败：" + Self.message(code)
      self.publish()
    }
  }
  func rebindVideo(hardware: String, enabled: Bool, position: Double, rate: Double, host: Double) {
    queue.async { [weak self] in
      guard let self, !self.stopped, let handle = self.handle else { return }
      // Freeing an active render context clears the selected track but leaves the
      // vid option at auto. Writing auto again alone is a no-op in mpv 0.41.
      let target = position + max(0, ProcessInfo.processInfo.systemUptime - host) * rate
      let result = pili_mpv_rebind_video(handle, hardware, enabled ? 1 : 0, self.snapshot.loaded ? max(0, target) : -1)
      if result < 0, self.snapshot.loaded { self.snapshot.failure = Self.message(result); self.publish() }
    }
  }
  func load(_ url: String, audio: String?, reference: String, start: Double, paused: Bool,
            generation: UUID, options: [String: String], after ready: DispatchGroup? = nil) {
    queue.async { [weak self] in
      // The render context first (MPVRenderer.prepareForLoad): commands stay in order, and the
      // video output finds a context when the file opens.
      ready?.wait()
      guard let self, !self.stopped else { return }
      if let error = self.startupError {
        self.snapshot = MPVSnapshot(generation: generation)
        self.snapshot.failure = error
        self.publish()
        return
      }
      guard let handle = self.handle else { return }
      self.run(["stop"])
      while mpv_wait_event(handle, 0).pointee.event_id != MPV_EVENT_NONE {}
      self.finishSeeks(false)
      self.snapshot = MPVSnapshot(generation: generation)
      self.snapshot.speed = Double(options["speed"] ?? "1") ?? 1
      self.entryID = -1
      self.needsExternalAudio = !(audio ?? "").isEmpty
      for (key, value) in options { mpv_set_property_string(handle, key, value) }
      let code = pili_mpv_load(handle, url, audio ?? "", reference,
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        start, paused ? 1 : 0)
      if code < 0 { self.snapshot.failure = Self.message(code) }
      self.snapshot.paused = paused
      self.publish()
    }
  }
  func stop() {
    queue.async { [weak self] in
      guard let self, !self.stopped else { return }
      self.run(["stop"])
      self.finishSeeks(false)
      self.snapshot = MPVSnapshot()
    }
  }
  func seek(_ seconds: Double, completion: @escaping (Bool) -> Void) {
    queue.async { [weak self] in
      guard let self, !self.stopped else { DispatchQueue.main.async { completion(false) }; return }
      self.finishSeeks(false)
      let request = UUID()
      self.seekID = request
      self.seekTarget = seconds
      self.seeks.append(completion)
      let code = self.run(["seek", String(seconds), "absolute+exact"])
      if code < 0 { self.finishSeeks(false) }
      else { self.snapshot.ended = false; self.snapshot.position = seconds; self.snapshot.positionHost = ProcessInfo.processInfo.systemUptime; self.publish() }
      self.queue.asyncAfter(deadline: .now() + .seconds(20)) { [weak self] in
        guard let self, self.seekID == request else { return }
        self.finishSeeks(false)
      }
    }
  }
  func command(_ arguments: [String]) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async { [weak self] in
        guard let self, !self.stopped else { continuation.resume(throwing: CancellationError()); return }
        let result = self.run(arguments)
        if result < 0 { continuation.resume(throwing: NSError(domain: "libmpv", code: Int(result),
          userInfo: [NSLocalizedDescriptionKey: Self.message(result)])) }
        else { continuation.resume() }
      }
    }
  }
  @discardableResult private func run(_ arguments: [String]) -> Int32 {
    guard let handle else { return -1 }
    let allocated = arguments.map { strdup($0) }
    defer { allocated.forEach { free($0) } }
    let pointers: [UnsafePointer<CChar>?] = allocated.map { pointer in
      pointer.map { UnsafePointer<CChar>($0) }
    } + [nil]
    return pointers.withUnsafeBufferPointer { pili_mpv_command(handle, $0.baseAddress) }
  }
  private func finishSeeks(_ success: Bool) {
    let pending = seeks
    seeks.removeAll()
    seekTarget = nil
    if !pending.isEmpty { DispatchQueue.main.async { pending.forEach { $0(success) } } }
  }
  private func seedLoadedProperties(_ handle: OpaquePointer) {
    // mpv coalesces observations: equal values across two files need not emit again.
    // Seed the new generation even when duration, dimensions or speed are unchanged.
    func number(_ name: String, fallback: Double) -> Double {
      var value = fallback
      return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 && value.isFinite ? value : fallback
    }
    func flag(_ name: String, fallback: Bool) -> Bool {
      var value: Int32 = fallback ? 1 : 0
      return mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 ? value != 0 : fallback
    }
    snapshot.position = max(0, number("time-pos", fallback: snapshot.position))
    snapshot.positionHost = ProcessInfo.processInfo.systemUptime
    snapshot.duration = max(0, number("duration", fallback: snapshot.duration))
    snapshot.speed = number("speed", fallback: snapshot.speed)
    snapshot.cacheEnd = number("demuxer-cache-time", fallback: snapshot.cacheEnd)
    snapshot.paused = flag("pause", fallback: snapshot.paused)
    snapshot.buffering = flag("paused-for-cache", fallback: snapshot.buffering)
    var params = mpv_node()
    if mpv_get_property(handle, "video-out-params", MPV_FORMAT_NODE, &params) >= 0 {
      updateVideoSize(params)
      mpv_free_node_contents(&params)
    }
  }
  // dw/dh include pixel aspect and crop. GL applies any remaining rotation when it draws.
  private func updateVideoSize(_ params: mpv_node) {
    guard params.format == MPV_FORMAT_NODE_MAP, let list = params.u.list?.pointee,
      let keys = list.keys, let values = list.values else { return }
    var width: Int64 = 0, height: Int64 = 0, rotation: Int64 = 0
    for i in 0..<Int(list.num) where values[i].format == MPV_FORMAT_INT64 {
      guard let key = keys[i] else { continue }
      switch String(cString: key) {
      case "dw": width = values[i].u.int64
      case "dh": height = values[i].u.int64
      case "rotate": rotation = values[i].u.int64
      default: break
      }
    }
    guard width > 0, height > 0 else { return }
    let sideways = abs(rotation % 180) == 90
    snapshot.width = sideways ? height : width
    snapshot.height = sideways ? width : height
  }
  private func poll() {
    guard !stopped, let handle else { return }
    var urgent = false
    // A bounded drain also lets queued speed/seek/pause commands run during event bursts.
    for _ in 0..<256 {
      let event = mpv_wait_event(handle, 0).pointee
      if event.event_id == MPV_EVENT_NONE { break }
      switch event.event_id {
      case MPV_EVENT_START_FILE:
        entryID = event.data.assumingMemoryBound(to: mpv_event_start_file.self).pointee.playlist_entry_id
      case MPV_EVENT_FILE_LOADED:
        seedLoadedProperties(handle)
        snapshot.loaded = true
        if needsExternalAudio {
          var audioID: Int64 = 0
          if mpv_get_property(handle, "aid", MPV_FORMAT_INT64, &audioID) < 0 || audioID <= 0 {
            snapshot.failure = "独立音轨加载失败"
          }
        }
        urgent = true
      case MPV_EVENT_PLAYBACK_RESTART:
        if let target = seekTarget {
          var actual = 0.0
          if mpv_get_property(handle, "time-pos", MPV_FORMAT_DOUBLE, &actual) >= 0,
            abs(actual - target) < 0.5 { finishSeeks(true) }
        }
        urgent = true
      case MPV_EVENT_END_FILE:
        let end = event.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
        if end.playlist_entry_id == entryID {
          if end.reason == MPV_END_FILE_REASON_ERROR { snapshot.failure = Self.message(end.error); finishSeeks(false) }
          if end.reason == MPV_END_FILE_REASON_EOF { snapshot.ended = true }
          urgent = true
        }
      case MPV_EVENT_PROPERTY_CHANGE:
        let value = event.data.assumingMemoryBound(to: mpv_event_property.self).pointee
        guard let data = value.data else { continue }
        let name = String(cString: value.name)
        if value.format == MPV_FORMAT_DOUBLE {
          let number = data.assumingMemoryBound(to: Double.self).pointee
          guard number.isFinite else { continue }
          switch name {
          case "time-pos": snapshot.position = max(0, number); snapshot.positionHost = ProcessInfo.processInfo.systemUptime
          case "duration": snapshot.duration = max(0, number)
          case "speed": snapshot.speed = number
          case "demuxer-cache-time": snapshot.cacheEnd = number
          default: break
          }
        } else if value.format == MPV_FORMAT_FLAG {
          let flag = data.assumingMemoryBound(to: Int32.self).pointee != 0
          switch name {
          case "pause": snapshot.paused = flag
          case "paused-for-cache": snapshot.buffering = flag
          case "eof-reached": snapshot.ended = flag
          default: break
          }
        } else if name == "video-out-params", value.format == MPV_FORMAT_NODE {
          updateVideoSize(data.assumingMemoryBound(to: mpv_node.self).pointee)
        }
      default: break
      }
    }
    if urgent || ProcessInfo.processInfo.systemUptime - lastPublish >= 0.1 { publish() }
    queue.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in self?.poll() }
  }
  private func publish() {
    lastPublish = ProcessInfo.processInfo.systemUptime
    mailboxLock.lock()
    mailbox = snapshot
    let schedule = !deliveryQueued
    deliveryQueued = true
    mailboxLock.unlock()
    guard schedule else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.mailboxLock.lock()
      let value = self.mailbox
      let callback = self.receiver
      self.mailbox = nil
      self.deliveryQueued = false
      self.mailboxLock.unlock()
      if let value { callback?(value) }
    }
  }
  /// Called after the GL renderer has freed its render context.
  func shutdown() {
    queue.async { [self] in
      guard !stopped else { return }
      stopped = true
      finishSeeks(false)
      if let handle { mpv_terminate_destroy(handle) }
    }
  }
}
