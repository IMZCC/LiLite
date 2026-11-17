import AVFoundation
import Foundation
import ObjectiveC

protocol OfflinePlaybackBridge: AnyObject, Sendable {
  func seek(to seconds: Double)
  func close()
  func takeRemainingDecoderRoutes() -> [NativeVideoRoute]
}
extension DashBridge: OfflinePlaybackBridge {}
extension LegacyDURLPlayback: OfflinePlaybackBridge {}

final class OfflineDecoderSource: @unchecked Sendable {
  let video: LocalFragmentIndex, audio: LocalFragmentIndex?
  let videoStream: DashStream, audioStream: DashStream?
  private let owner: String?
  let lease: OfflinePlaybackFiles?
  let remote: ProgressiveMediaRanges?
  private let remoteAudio:ProgressiveMediaRanges?
  let volume: AudioMeasurements?
  init(
    video: LocalFragmentIndex, audio: LocalFragmentIndex?, quality: Int, owner: String?,
    lease: OfflinePlaybackFiles? = nil, remote: ProgressiveMediaRanges? = nil,remoteAudio:ProgressiveMediaRanges?=nil,
    volume: AudioMeasurements? = nil
  ) {
    self.video = video
    self.audio = audio
    self.owner = owner
    self.lease = lease
    self.remote = remote;self.remoteAudio=remoteAudio
    self.volume = volume
    func stream(_ index: LocalFragmentIndex, id: Int) -> DashStream {
      .init(
        localID: id, codec: index.codec, rate: index.bitrate, width: index.width,
        height: index.height,
        initial: "\(index.initial.lower)-\(index.initial.upper)")
    }
    videoStream = stream(video, id: quality)
    audioStream = audio.map { stream($0, id: 0) }
  }
  static func open(
    lease: OfflinePlaybackFiles, quality: Int?, owner: String?, volume: AudioMeasurements? = nil
  ) async throws
    -> OfflineDecoderSource?
  {
    let movie = lease.files["movie"]
    let video = lease.files["video"]
    let af = lease.files["audio"]
    guard movie != nil || video != nil else { return nil }
    let task = Task.detached(priority: .userInitiated) { () throws -> OfflineDecoderSource in
      try Task.checkCancellation()
      let v: LocalFragmentIndex
      let a: LocalFragmentIndex?
      if let movie {
        (v, a) = try LocalMovieFragments.open(LocalMediaFile(movie))
      } else if let video {
        v = try LocalFragmentIndex(url: video, audio: false)
        a = try af.map { try LocalFragmentIndex(url: $0, audio: true) }
      } else {
        throw LocalIndexIssue.invalid
      }
      try Task.checkCancellation()
      return OfflineDecoderSource(
        video: v, audio: a, quality: quality ?? 0, owner: owner, lease: lease, volume: volume)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
  func authorize() async throws {
    try Task.checkCancellation()
    if let owner {
      let current = remote == nil
        ? try await AccountJar.shared.localOwner(.role(.video))
        : try await AccountJar.shared.current(.role(.video))?.id
      guard (current ?? "") == owner else { throw ServiceError("视频账号已切换") }
    }
  }
  func read(_ range: ByteSpan, audio isAudio: Bool) async throws -> Data {
    try await authorize()
    guard let index = isAudio ? audio : video, range.count > 0, range.count <= 48 * 1024 * 1024
    else { throw LocalIndexIssue.invalid }
    let data: Data
    if let remote = isAudio ? (remoteAudio ?? remote):remote,let mapped=index.file as? LocalMovieFragments{
      data = try await mapped.online(range.lower, Int(range.count)) { a, n in
        let response = try await remote.read(a, n)
        guard response.total == mapped.originalLength else { throw LocalIndexIssue.invalid }
        return response.data
      }
    } else {
      data = try index.file.data(range.lower, Int(range.count))
    }
    try await authorize()
    return data
  }
}
@MainActor enum OfflineDecoderItem {
  private static var leaseKey: UInt8 = 0, recoveryKey: UInt8 = 0
  private enum Source {
    case standard(OfflineDecoderSource)
    case legacy(OfflinePlaybackFiles, OfflineVideo)
  }
  private final class Context {
    let source: Source, bridge: any OfflinePlaybackBridge
    var observer: NSObjectProtocol?
    init(_ source: Source, _ bridge: any OfflinePlaybackBridge, item: AVPlayerItem) {
      self.source = source
      self.bridge = bridge
      observer = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemTimeJumped, object: nil, queue: .main
      ) { [weak item, weak bridge] event in
        guard let item, let active = event.object as? AVPlayerItem, active === item else { return }
        let seconds = item.currentTime().seconds
        if seconds.isFinite { bridge?.seek(to: seconds) }
      }
    }
    deinit {
      if let observer { NotificationCenter.default.removeObserver(observer) }
      bridge.close()
    }
  }
  static func item(
    lease: OfflinePlaybackFiles, quality: Int?, owner: String?, volume: AudioMeasurements? = nil
  ) async throws
    -> AVPlayerItem?
  {
    let source: OfflineDecoderSource?
    do {
      source = try await OfflineDecoderSource.open(
        lease: lease, quality: quality, owner: owner, volume: volume)
    } catch LocalIndexIssue.external {
      throw ServiceError("此缓存引用了外部媒体")
    } catch LocalIndexIssue.encrypted { throw ServiceError("此缓存含受保护的媒体轨道") } catch LocalIndexIssue
      .notFragmented
    {
      if DecoderPreference.allowsSystemFallback { return nil }
      throw ServiceError("此缓存没有可供所选解码方式使用的分段索引")
    } catch LocalIndexIssue.invalid {
      if DecoderPreference.allowsSystemFallback { return nil }
      throw ServiceError("无法读取缓存的分轨信息")
    }
    guard let source else {
      if DecoderPreference.allowsSystemFallback { return nil }
      throw ServiceError("此缓存需要在视频解码中选择自动")
    }
    return try await make(.standard(source), routes: nil)
  }
  static func legacyItem(lease: OfflinePlaybackFiles, row: OfflineVideo) async throws -> AVPlayerItem {
    try await make(.legacy(lease, row), routes: nil)
  }
  private static func make(_ source: Source, routes: [NativeVideoRoute]?) async throws
    -> AVPlayerItem
  {
    let bridge: any OfflinePlaybackBridge
    let open: () async throws -> URL
    switch source {
    case .standard(let local):
      let next = DashBridge(local: local, decoding: routes)
      bridge = next
      open = { let url = try await next.startLocal(); try await local.authorize(); return url }
    case .legacy(let lease, let row):
      let next = try LegacyDURLPlayback(offline: lease, row: row, routes: routes)
      bridge = next; open = { try await next.start() }
    }
    do {
      let url = try await open()
      let item = AVPlayerItem(url: url)
      objc_setAssociatedObject(
        item, &leaseKey, Context(source, bridge, item: item), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
      return item
    } catch {
      bridge.close()
      throw error
    }
  }
  static func aboutToSeek(_ player: AVPlayer, to seconds: Double) {
    guard let item = player.currentItem,
      let ctx = objc_getAssociatedObject(item, &leaseKey) as? Context
    else { return }
    ctx.bridge.seek(to: seconds)
  }
  @MainActor private final class Recovery {
    weak var player: AVPlayer?
    let issue: (String) -> Void
    private var watch: NSKeyValueObservation?, rate: NSKeyValueObservation?,
      failure: NSObjectProtocol?
    private var task: Task<Void, Never>?, wanted: Float = 1
    private var replacement = UUID(), active = true
    private var sound: NSObjectProtocol?, soundTask: Task<Void, Never>?,
      soundPrefs = AudioFilterChoice.snapshot
    init(_ player: AVPlayer, issue: @escaping (String) -> Void) {
      self.player = player
      self.issue = issue
      rate = player.observe(\.rate, options: [.new]) { [weak self] p, _ in
        Task { @MainActor in
          if p.rate > 0 {
            self?.wanted = p.rate
          } else if p.currentItem?.status == .readyToPlay && p.currentItem?.error == nil
            && p.timeControlStatus == .paused
          {
            self?.wanted = 0
          }
        }
      }
      sound = NotificationCenter.default.addObserver(
        forName: UserDefaults.didChangeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.soundChanged() }
      }
      if let item = player.currentItem { attach(item) }
    }
    private func soundChanged() {
      let next = AudioFilterChoice.snapshot
      guard active, next != soundPrefs else { return }
      soundPrefs = next
      soundTask?.cancel()
      soundTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard let self, !Task.isCancelled, let item = self.player?.currentItem,
          let ctx = objc_getAssociatedObject(item, &leaseKey) as? Context
        else { return }
        self.replace(item, ctx: ctx, rest: nil)
      }
    }
    private func attach(_ item: AVPlayerItem) {
      watch?.invalidate()
      if let failure { NotificationCenter.default.removeObserver(failure) }
      watch = item.observe(\.status, options: [.initial, .new]) { [weak self] i, _ in
        if i.status == .failed { Task { @MainActor in self?.failed(i) } }
      }
      failure = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main
      ) { [weak self, weak item] note in
        guard let item, let i = note.object as? AVPlayerItem, item === i else { return }
        Task { @MainActor in self?.failed(i) }
      }
    }
    private func failed(_ item: AVPlayerItem) {
      guard task == nil, let p = player, p.currentItem === item else { return }
      guard let ctx = objc_getAssociatedObject(item, &leaseKey) as? Context else {
        issue(item.error?.localizedDescription ?? "离线视频无法播放")
        return
      }
      let rest = ctx.bridge.takeRemainingDecoderRoutes()
      guard !rest.isEmpty else {
        issue(item.error?.localizedDescription ?? "离线视频无法播放")
        return
      }
      replace(item, ctx: ctx, rest: rest)
    }
    private func replace(_ item: AVPlayerItem, ctx: Context, rest: [NativeVideoRoute]?) {
      guard let p = player, p.currentItem === item else { return }
      task?.cancel()
      let token = UUID()
      replacement = token
      let position = p.currentTime()
      task = Task { [weak self, weak p] in
        guard let self, let p else { return }
        defer {
          if self.replacement == token { self.task = nil }
          if self.replacement == token, !Task.isCancelled, let active = p.currentItem,
            active !== item,
            active.status == .failed
          {
            self.failed(active)
          }
        }
        do {
          let next = try await OfflineDecoderItem.make(ctx.source, routes: rest)
          try Task.checkCancellation()
          guard p.currentItem === item else { return }
          let intended = self.wanted
          p.replaceCurrentItem(with: next)
          self.attach(next)
          if position.seconds.isFinite && position.seconds > 0 {
            _ = await p.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
          }
          guard !Task.isCancelled, p.currentItem === next else { return }
          PlaybackSleepTimer.shared.bind(p, item: next, handlesEnd: true)
          if intended > 0 { p.playImmediately(atRate: intended) }
        } catch { if !Task.isCancelled { self.issue(error.localizedDescription) } }
      }
    }
    func stop() {
      active = false
      replacement = UUID()
      soundTask?.cancel()
      if let sound {
        NotificationCenter.default.removeObserver(sound)
        self.sound = nil
      }
      task?.cancel()
      task = nil
      watch?.invalidate()
      rate?.invalidate()
      if let failure {
        NotificationCenter.default.removeObserver(failure)
        self.failure = nil
      }
    }
    deinit {
      soundTask?.cancel()
      if let sound { NotificationCenter.default.removeObserver(sound) }
      task?.cancel()
      if let failure { NotificationCenter.default.removeObserver(failure) }
    }
  }
  static func bind(_ player: AVPlayer, issue: @escaping (String) -> Void) {
    objc_setAssociatedObject(
      player, &recoveryKey, Recovery(player, issue: issue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
  }
  static func stop(_ player: AVPlayer) {
    (objc_getAssociatedObject(player, &recoveryKey) as? Recovery)?.stop()
    objc_setAssociatedObject(player, &recoveryKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    if let item = player.currentItem,
      let ctx = objc_getAssociatedObject(item, &leaseKey) as? Context
    {
      ctx.bridge.close()
    }
  }
}
