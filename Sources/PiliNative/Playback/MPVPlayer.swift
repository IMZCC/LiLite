import AVFoundation
import Combine
import UIKit

@MainActor final class MPVPlayer: NSObject, PlaybackEngine {
  final class Item: NSObject {
    let generation = UUID()
    let url: String
    init(url: String) { self.url = url }
  }
  let core: MPVCore
  let renderer: MPVRenderer
  let engineKind = PlaybackEngineKind.mpv
  private(set) var currentItem: Item?
  private var state = MPVSnapshot()
  private let items = CurrentValueSubject<AnyObject?, Never>(nil)
  private let changes = PassthroughSubject<Void, Never>()
  private var normalSpeed: Float = 1
  private var volume: Float = 1
  private var muted = false
  private var ended = false
  private var request: (video: String, audio: String?, reference: URL, volume: AudioMeasurements?)?
  private var interruptions: PlaybackSessionEvents?
  private var interruptedItem: Item?
  private var resumeRate: Float = 0
  private var backgroundItem: Item?
  private var backgroundRate: Float = 0
  private var notifications: [NSObjectProtocol] = []
  private var picture: MPVPiPSession?
  private var preferredHardware = "videotoolbox"
  private var inactive = false
  var backgroundOverride: Bool?
  var audioOnly = false { didSet { updateVideoTrack() } }
  var onUpdate: (() -> Void)?
  var onEnd: (() -> Void)?
  var onFailure: ((String) -> Void)?
  var backgroundPlaybackAllowed: Bool { backgroundOverride ?? UserDefaults.standard.bool(forKey: VideoTransport.backgroundKey) }
  var continuesInBackground: Bool { picture?.keepsVideo == true || backgroundPlaybackAllowed }
  var playbackItem: AnyObject? { currentItem }
  var playbackDuration: Double { state.duration }
  var playbackSize: CGSize { CGSize(width: Int(state.width), height: Int(state.height)) }
  var playbackReady: Bool { state.loaded && state.failure == nil && currentItem != nil }
  var playbackBuffers: [ClosedRange<Double>] {
    state.cacheEnd > state.position ? [state.position...state.cacheEnd] : []
  }
  var itemPublisher: AnyPublisher<AnyObject?, Never> { items.eraseToAnyPublisher() }
  var statePublisher: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }
  var defaultRate: Float {
    get { normalSpeed }
    set {
      guard newValue.isFinite, newValue > 0, newValue <= 100 else { return }
      normalSpeed = newValue
      setSpeed(newValue)
    }
  }
  var rate: Float {
    get { state.paused || state.ended ? 0 : Float(state.speed) }
    set {
      if newValue == 0 { pause() }
      else if newValue.isFinite, newValue > 0, newValue <= 100 { setSpeed(newValue) }
    }
  }
  var presentationVolume: Float {
    get { volume }
    set {
      guard newValue.isFinite else { return }
      volume = min(1, max(0, newValue))
      core.set("volume", String(volume * 100))
    }
  }
  var isMuted: Bool {
    get { muted }
    set { muted = newValue; core.set("mute", newValue ? "yes" : "no") }
  }
  var isExternalPlaybackActive: Bool { false }
  var timeControlStatus: AVPlayer.TimeControlStatus {
    state.paused || state.ended ? .paused : state.buffering || !state.loaded ? .waitingToPlayAtSpecifiedRate : .playing
  }
  override init() {
    let client = MPVCore()
    core = client
    renderer = MPVRenderer(core: client, active: UIApplication.shared.applicationState == .active)
    super.init()
    inactive = UIApplication.shared.applicationState != .active
    client.observe { [weak self] value in self?.receive(value) }
    interruptions = PlaybackSessionEvents { [weak self] signal in self?.interruption(signal) }
    for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification] {
      notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        MainActor.assumeIsolated {
          guard let self else { return }
          let position = self.currentTime().seconds
          let host = ProcessInfo.processInfo.systemUptime
          let rate = self.timeControlStatus == .playing ? Double(self.rate) : 0
          if note.name == UIApplication.willResignActiveNotification {
            self.picture?.willResignActive()
            self.inactive = true
            self.renderer.setSuspended(true)
            self.core.rebindVideo(hardware: self.preferredHardware == "no" ? "no" : "videotoolbox-copy",
              enabled: !self.audioOnly && self.picture?.keepsVideo == true, position: position, rate: rate, host: host)
          } else if note.name == UIApplication.didEnterBackgroundNotification {
            self.picture?.didEnterBackground()
            self.refreshBackgroundPolicy()
          } else if note.name == UIApplication.didBecomeActiveNotification {
            self.inactive = false
            self.renderer.setSuspended(false)
            self.core.rebindVideo(hardware: self.preferredHardware, enabled: !self.audioOnly, position: position, rate: rate, host: host)
            self.picture?.didBecomeActive()
            PlaybackSleepTimer.shared.check()
            let item = self.backgroundItem
            let speed = self.backgroundRate
            self.backgroundItem = nil
            self.backgroundRate = 0
            if let item, item === self.currentItem, speed > 0, self.rate == 0,
              !ListenQueue.shared.playing, !ListenQueue.shared.loading { self.playImmediately(atRate: speed) }
          }
          self.updateVideoTrack()
        }
      })
    }
  }
  deinit {
    MainActor.assumeIsolated { picture?.invalidate() }
    for token in notifications { NotificationCenter.default.removeObserver(token) }
    let client = core
    client.stop()
    renderer.close { client.shutdown() }
  }
  private func receive(_ next: MPVSnapshot) {
    guard let item = currentItem, next.generation == item.generation else { return }
    let priorFailure = state.failure
    let changed = state.paused != next.paused || state.speed != next.speed
      || state.buffering != next.buffering || state.loaded != next.loaded || state.ended != next.ended
      || state.width != next.width || state.height != next.height || priorFailure != next.failure
    state = next
    if changed { changes.send() }
    onUpdate?()
    if let failure = next.failure, priorFailure != failure { onFailure?(failure) }
    if next.ended && !ended { ended = true; onEnd?() }
    if !next.ended { ended = false }
  }
  func load(video: String, audio: String?, reference: URL, start: Double, autoplay: Bool,
            volume: AudioMeasurements? = nil) {
    renderer.setPageReleased(false)
    request = (video, audio, reference, volume)
    cancelInterruption()
    currentItem = Item(url: video)
    guard let item = currentItem else { return }
    state = MPVSnapshot(generation: item.generation)
    state.speed = Double(normalSpeed)
    state.paused = !autoplay
    ended = false
    items.send(item)
    let defaults = UserDefaults.standard
    let hardware = defaults.object(forKey: DecoderPreference.enabledKey) as? Bool ?? true
    let choices = DecoderPreference.choices(defaults.string(forKey: DecoderPreference.listKey) ?? "auto") ?? ["auto"]
    let copy = choices.first.map { $0.contains("copy") } ?? false
    let soft = choices.first == "no"
    preferredHardware = !hardware || soft ? "no" : copy ? "videotoolbox-copy" : "videotoolbox"
    let buffer = MediaBufferPolicy.current(live: false)
    let stored = defaults.object(forKey: VideoTransport.bufferKey) as? Double ?? 16
    // The original's initBuffer: the buffered duration scales with the playback speed, and the
    // demuxer resumes filling once a third of it has been played.
    let seconds = (stored.isFinite ? max(0, min(3600, stored)) : 16) * Double(max(0.1, normalSpeed))
    let sync = PresentationMode.current
    let filters = AudioFilterChoice.current(volume)
    let options = [
      "hwdec": inactive && preferredHardware != "no" ? "videotoolbox-copy" : preferredHardware,
      "sws-fast": "yes", "sws-scaler": "bilinear",
      "cache": "yes", "cache-secs": String(format: "%.3f", seconds),
      "demuxer-hysteresis-secs": String(format: "%.3f", seconds / 1.5),
      "demuxer-max-bytes": String(max(1024 * 1024, buffer)),
      "demuxer-max-back-bytes": String(buffer), "speed": String(normalSpeed),
      // "系统自动" on mpv is the original's default, display-resample.
      "video-sync": sync == .system ? PresentationMode.resample.rawValue : sync.rawValue,
      "autosync": String(PresentationMode.smoothing),
      "af": filters.isEmpty ? "" : "lavfi=[\(filters)]",
    ]
    activateAudio()
    let ready = renderer.prepareForLoad()
    core.load(video, audio: audio, reference: reference.absoluteString, start: start,
      paused: !autoplay, generation: item.generation, options: options, after: ready)
    updateVideoTrack()
    if autoplay { didPlay() }
  }
  func refreshSound(_ volume: AudioMeasurements?) {
    let filters = AudioFilterChoice.current(volume)
    core.set("af", filters.isEmpty ? "" : "lavfi=[\(filters)]")
  }
  func currentTime() -> CMTime {
    let elapsed = timeControlStatus == .playing ? min(0.25, max(0, ProcessInfo.processInfo.systemUptime - state.positionHost)) : 0
    return CMTime(seconds: min(state.duration > 0 ? state.duration : .greatestFiniteMagnitude,
      state.position + elapsed * state.speed), preferredTimescale: 600_000)
  }
  func previewCopy() -> MPVPlayer? {
    guard let request else { return nil }
    let copy = MPVPlayer()
    copy.load(video: request.video, audio: request.audio, reference: request.reference, start: 0,
      autoplay: false, volume: request.volume)
    return copy
  }
  private func setSpeed(_ value: Float) {
    state.speed = Double(value)
    core.set("speed", String(value))
    changes.send()
  }
  private func activateAudio() {
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    try? AVAudioSession.sharedInstance().setActive(true)
  }
  private func didPlay() {
    ListenQueue.shared.yieldPlaybackToVideo()
    if let item = currentItem { PlaybackSleepTimer.shared.beganVideo(self, item: item) }
  }
  func play() {
    guard currentItem != nil else { return }
    cancelInterruption()
    activateAudio()
    if state.ended { seek(to: .zero) }
    state.paused = false
    setSpeed(normalSpeed)
    core.set("pause", "no")
    didPlay()
    changes.send()
  }
  func pause() {
    cancelInterruption()
    state.paused = true
    core.set("pause", "yes")
    changes.send()
  }
  func playImmediately(atRate speed: Float) { play(); setSpeed(speed) }
  func stop() {
    cancelInterruption()
    core.stop()
    currentItem = nil
    state = MPVSnapshot()
    picture?.stopPlayback()
    items.send(nil)
    changes.send()
  }
  func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime, completionHandler: @escaping (Bool) -> Void) {
    guard time.isNumeric, time.seconds.isFinite, let item = currentItem else { completionHandler(false); return }
    let target = min(state.duration > 0 ? state.duration : .greatestFiniteMagnitude, max(0, time.seconds))
    state.position = target
    state.positionHost = ProcessInfo.processInfo.systemUptime
    state.ended = false
    ended = false
    core.seek(target) { [weak self, weak item] ok in
      guard let self, let item, self.currentItem === item else { completionHandler(false); return }
      NotificationCenter.default.post(name: .piliEngineTimeJumped, object: item)
      completionHandler(ok)
    }
    changes.send()
  }
  private final class ClockToken {
    var timer: Timer?
    deinit { timer?.invalidate() }
  }
  func addPeriodicTimeObserver(forInterval interval: CMTime, queue: DispatchQueue?, using block: @escaping (CMTime) -> Void) -> Any {
    let token = ClockToken()
    let timer = Timer(timeInterval: max(0.05, interval.seconds), repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { if let self { block(self.currentTime()) } }
    }
    token.timer = timer
    RunLoop.main.add(timer, forMode: .common)
    return token
  }
  func removeTimeObserver(_ observer: Any) { (observer as? ClockToken)?.timer?.invalidate() }
  func cancelInterruption() {
    interruptedItem = nil
    resumeRate = 0
    backgroundItem = nil
    backgroundRate = 0
  }
  private func interruption(_ signal: PlaybackSessionEvents.Signal) {
    switch signal {
    case .systemInterruption:
      let item = currentItem
      let speed = rate
      pause()
      if speed > 0 { interruptedItem = item; resumeRate = speed }
    case .outputLost: pause()
    case .appInactive: break
    case .recommendation(let allowed):
      let item = interruptedItem
      let speed = resumeRate
      cancelInterruption()
      if allowed, let item, item === currentItem, speed > 0,
        UIApplication.shared.applicationState != .background || continuesInBackground {
        playImmediately(atRate: speed)
      }
    }
  }
  func preparePiP(in window: UIWindow) {
    if picture == nil { picture = MPVPiPSession(player: self) }
    picture?.attach(to: window)
  }
  func refreshBackgroundPolicy(allowPause: Bool = true) {
    if allowPause, UIApplication.shared.applicationState == .background, !continuesInBackground, rate > 0 {
      let item = currentItem
      let speed = rate
      pause()
      if UserDefaults.standard.bool(forKey: InterfaceInteraction.pauseWhenBackground) {
        backgroundItem = item
        backgroundRate = speed
      }
    }
    updateVideoTrack()
  }
  private func updateVideoTrack() {
    core.set("vid", audioOnly || (inactive && picture?.keepsVideo != true) ? "no" : "auto")
  }
  func screenshot(to url: URL) async throws {
    let item = currentItem
    guard playbackReady else { throw ServiceError("请等待播放器就绪") }
    try await core.command(["screenshot-to-file", url.path, "video"])
    guard item === currentItem else { throw ServiceError("视频已切换") }
  }
}

extension Notification.Name {
  static let piliEngineTimeJumped = Notification.Name("PiliNative.engineTimeJumped")
}
