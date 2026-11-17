import Foundation

#if canImport(Combine)
  import Combine
#endif

enum CastTransportState: String {
  case playing = "PLAYING"
  case paused = "PAUSED_PLAYBACK"
  case stopped = "STOPPED"
  case waiting = "TRANSITIONING"
  case empty = "NO_MEDIA_PRESENT"
  case unknown = ""
  var label: String {
    switch self {
    case .playing: "正在播放"
    case .paused: "已暂停"
    case .stopped: "已停止"
    case .waiting: "正在缓冲"
    case .empty: "没有媒体"
    case .unknown: "已连接"
    }
  }
}
struct CastReadback {
  var state = CastTransportState.unknown, position: Double?, duration: Double?, volume: Double?,
    muted: Bool?, actions: Set<String>?
}
struct CastLocalPlayback {
  let position: @MainActor () -> Double, hold: @MainActor () -> Void,
    resume: @MainActor (Double) async throws -> Void
  var available: @MainActor () -> Bool = { true }
}
final class CastLease {
  let url: URL, mime: String
  private let release: () -> Void
  private var closed = false
  init(_ u: URL, mime: String, release: @escaping () -> Void) {
    url = u
    self.mime = mime
    self.release = release
  }
  func close() {
    guard !closed else { return }
    closed = true
    release()
  }
  deinit { close() }
}
@MainActor final class CastState: ObservableObject {
  static let shared = CastState()
  struct Active {
    let id = UUID()
    let subject: CastSubject, device: CastDevice, client: CastClient, lease: CastLease,
      local: CastLocalPlayback
  }
  @Published private(set) var device: CastDevice?
  @Published private(set) var subject: CastSubject?
  @Published private(set) var now = CastReadback()
  @Published private(set) var busy = false
  @Published private(set) var offline = false
  @Published var issue: String?
  private var active: Active?, watch: Task<Void, Never>?, expiry: Task<Void, Never>?,
    epoch = UUID(), failures = 0
  private var disabled = Set<CastAction>(), revision = UUID()
  private let automatic: Bool
  init(automatic: Bool = true) { self.automatic = automatic }
  func supports(_ a: CastAction) -> Bool {
    guard let active, !disabled.contains(a), active.client.supports(a) else { return false }
    if [.play, .pause, .seek, .stop].contains(a), let actions = now.actions, !actions.isEmpty {
      return actions.contains(a.rawValue.uppercased())
    }
    return true
  }
  private func check(_ k: UUID) throws {
    try Task.checkCancellation()
    guard epoch == k else { throw CastProblem.stale }
  }
  private func invalid(_ err: Error) -> Bool {
    if case CastProblem.fault(let code, _) = err { return code == 401 || code == 602 }
    return false
  }
  private func read(_ a: CastAction, from s: Active, fields: [(String, String)] = []) async throws
    -> [String: String]?
  {
    guard s.client.supports(a), !disabled.contains(a) else { return nil }
    do { return try await s.client.call(a, fields) } catch {
      if invalid(error) {
        if active?.id == s.id { disabled.insert(a) }
        return nil
      }
      throw error
    }
  }
  private func belongs(_ s: Active, strict: Bool = false) async throws {
    let p = try await read(.position, from: s)
    let track = p?["TrackURI"]
    if let track, !track.isEmpty, track != "NOT_IMPLEMENTED" {
      guard track == s.lease.url.absoluteString else { throw CastProblem.foreign }
      return
    }
    if let m = try await read(.media, from: s), let uri = m["CurrentURI"], !uri.isEmpty,
      uri != "NOT_IMPLEMENTED"
    {
      guard uri == s.lease.url.absoluteString else { throw CastProblem.foreign }
      return
    }
    if strict { throw CastProblem.unsupported }
  }
  private func setURI(_ client: CastClient, _ lease: CastLease, title: String) async throws {
    let metadata = CastProtocol.metadata(title: title, uri: lease.url, mime: lease.mime)
    _ = try await client.call(
      .set, [("CurrentURI", lease.url.absoluteString), ("CurrentURIMetaData", metadata)])
  }
  private func seek(_ c: CastClient, _ time: Double) async throws {
    _ = try await c.call(.seek, [("Unit", "REL_TIME"), ("Target", CastProtocol.time(time))])
  }
  func start(
    subject new: CastSubject, device d: CastDevice, local: CastLocalPlayback,
    http: CastHTTP = CastHTTP(), make: @escaping @MainActor (CastDevice) async throws -> CastLease
  ) async throws {
    guard new.valid, !busy else { throw CastProblem.stale }
    if active?.subject == new, active?.device == d, !offline { return }
    let token = epoch
    let old = active
    let continuing =
      old?.subject.object == new.object && old?.subject.cid == new.cid
      && old?.subject.type == new.type
    let position = continuing ? now.position ?? local.position() : local.position()
    var lease: CastLease?
    var replaced = false
    var started = false
    revision = UUID()
    busy = true
    issue = nil
    defer { if epoch == token { busy = false } }
    do {
      var client = CastClient(d, http: http)
      await client.prepare()
      try check(token)
      guard client.supports(.set), client.supports(.play) else { throw CastProblem.unsupported }
      let m = try await make(d)
      lease = m
      try check(token)
      try await setURI(client, m, title: new.title)
      replaced = true
      try check(token)
      _ = try await client.call(.play, [("Speed", "1")])
      started = true
      try check(token)
      var placed = 0.0
      var note: String?
      if position.isFinite, position >= 1 {
        do {
          try await seek(client, position)
          placed = position
        } catch { note = "设备已从头播放，未接受进度跳转" }
      }
      try check(token)
      if let old, old.device != d {
        do {
          try await belongs(old, strict: true)
          _ = try await old.client.call(old.client.supports(.pause) ? .pause : .stop)
        } catch { if (error as? CastProblem) != .foreign { note = note ?? "新设备已播放，旧设备未确认暂停" } }
      }
      try check(token)
      watch?.cancel()
      expiry?.cancel()
      old?.lease.close()
      let active = Active(subject: new, device: d, client: client, lease: m, local: local)
      self.active = active
      self.subject = new
      device = d
      lease = nil
      disabled = []
      failures = 0
      offline = false
      now = CastReadback(state: .playing, position: placed)
      issue = note
      local.hold()
      if automatic { monitor(active.id) }
    } catch {
      // Only restore the previous program if the same renderer accepted its replacement but
      // rejected Play. Never stop or overwrite a foreign TV program after a lost ownership check.
      if replaced, epoch == token, let m = lease {
        let c = CastClient(d, http: http)
        if let old, old.device == d {
          do {
            let staged = Active(subject: new, device: d, client: c, lease: m, local: local)
            try await belongs(staged, strict: true)
            try await setURI(c, old.lease, title: old.subject.title)
            if now.state != .paused && now.state != .stopped {
              _ = try await c.call(.play, [("Speed", "1")])
            }
            if let t = now.position, t > 0 { try? await seek(c, t) }
          } catch { self.end() }
        } else if started {
          let a = Active(subject: new, device: d, client: c, lease: m, local: local)
          if (try? await belongs(a, strict: true)) != nil { _ = try? await c.call(.stop) }
        }
      }
      lease?.close()
      throw error
    }
  }
  private func monitor(_ id: UUID) {
    watch = Task { [weak self] in
      var round = 0
      while !Task.isCancelled {
        guard let self, self.active?.id == id else { return }
        if !self.busy {
          await self.refresh(extras: round % 3 == 0)
          round += 1
        }
        try? await Task.sleep(for: .seconds(self.offline ? 5 : 2))
      }
    }
    expiry = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(6 * 3600))
        if self?.active?.id == id { self?.end() }
      } catch {}
    }
  }
  func refresh(extras: Bool = true) async {
    guard let s = active, !busy else { return }
    let id = s.id
    let r = revision
    do {
      let t = try await read(.state, from: s)
      let p = try await read(.position, from: s)
      let track = p?["TrackURI"]
      if let uri = track, !uri.isEmpty, uri != "NOT_IMPLEMENTED" {
        if uri != s.lease.url.absoluteString { throw CastProblem.foreign }
      } else if extras, let m = try await read(.media, from: s), let uri = m["CurrentURI"],
        !uri.isEmpty, uri != "NOT_IMPLEMENTED", uri != s.lease.url.absoluteString
      {
        throw CastProblem.foreign
      }
      var n = now
      if let v = t?["CurrentTransportState"] {
        n.state = CastTransportState(rawValue: v) ?? .unknown
      }
      if let d = CastProtocol.seconds(p?["TrackDuration"]), d > 0 { n.duration = d }
      if let pos = CastProtocol.seconds(p?["RelTime"]) { n.position = pos }
      if extras {
        if let a = try? await read(.actions, from: s), let values = a["Actions"] {
          n.actions = Set(
            values.split(separator: ",").map {
              $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            })
        }
        if let v = try? await read(.volume, from: s, fields: [("Channel", "Master")]),
          let level = v["CurrentVolume"].flatMap(Int.init)
        {
          n.volume = s.client.rc.volumeRange.percent(level)
        }
        if let m = try? await read(.mute, from: s, fields: [("Channel", "Master")]),
          let flag = m["CurrentMute"]?.lowercased()
        {
          n.muted = ["1", "true", "yes"].contains(flag)
        }
      }
      guard active?.id == id, revision == r, !Task.isCancelled else { return }
      now = n
      failures = 0
      offline = false
    } catch {
      guard active?.id == id, revision == r, !Task.isCancelled else { return }
      if let p = error as? CastProblem, p == .foreign {
        end()
        issue = p.localizedDescription
      } else {
        failures += 1
        if failures >= 2 { offline = true }
      }
    }
  }
  enum Command {
    case play, pause, stop, phone
    case seek(Double)
    case volume(Double)
    case mute(Bool)
  }
  func perform(_ command: Command) async throws {
    guard !busy, let s = active else { throw CastProblem.stale }
    revision = UUID()
    busy = true
    let k = epoch
    defer { if epoch == k { busy = false } }
    if case .phone = command {
      guard s.local.available() else { throw ServiceError("请先回到投屏的视频，再继续播放") }
      if offline {
        let pos = now.position ?? 0
        end()
        try await s.local.resume(pos)
        return
      }
    }
    do {
      switch command {
      case .stop, .phone, .seek, .play, .pause: try await belongs(s, strict: true)
      case .volume, .mute: try await belongs(s)
      }
      try check(k)
      switch command {
      case .play:
        _ = try await s.client.call(.play, [("Speed", "1")])
        try check(k)
        now.state = .playing
      case .pause:
        _ = try await s.client.call(.pause)
        try check(k)
        now.state = .paused
      case .seek(let t):
        guard t.isFinite, t >= 0 else { throw CastProblem.unsupported }
        let value = min(t, now.duration ?? t)
        try await seek(s.client, value)
        try check(k)
        now.position = value
      case .volume(let v):
        guard v.isFinite else { throw CastProblem.unsupported }
        let n = s.client.rc.volumeRange.native(v)
        _ = try await s.client.call(
          .setVolume, [("Channel", "Master"), ("DesiredVolume", String(n))])
        try check(k)
        now.volume = s.client.rc.volumeRange.percent(n)
      case .mute(let m):
        _ = try await s.client.call(
          .setMute, [("Channel", "Master"), ("DesiredMute", m ? "1" : "0")])
        try check(k)
        now.muted = m
      case .phone, .stop:
        let playback: Bool
        if case .phone = command { playback = true } else { playback = false }
        let info = try? await read(.position, from: s)
        let pos = CastProtocol.seconds(info?["RelTime"]) ?? now.position ?? 0
        try check(k)
        _ = try await s.client.call(.stop)
        try check(k)
        end()
        if playback { try await s.local.resume(pos) }
      }
      if epoch == k {
        offline = false
        failures = 0
        now.actions = nil
        issue = nil
      }
    } catch {
      if let p = error as? CastProblem, p == .foreign, epoch == k {
        end()
        issue = p.localizedDescription
      }
      throw error
    }
  }
  func reconnect(
    http: CastHTTP = CastHTTP(),
    make: @escaping @MainActor (CastSubject, CastDevice) async throws -> CastLease
  ) async throws {
    guard let s = active, offline else { return }
    try await start(subject: s.subject, device: s.device, local: s.local, http: http) { device in
      try await make(s.subject, device)
    }
  }
  func end() {
    epoch = UUID()
    revision = UUID()
    watch?.cancel()
    watch = nil
    expiry?.cancel()
    expiry = nil
    active?.lease.close()
    active = nil
    subject = nil
    device = nil
    now = .init()
    offline = false
    busy = false
    failures = 0
    disabled = []
    issue = nil
  }
}
