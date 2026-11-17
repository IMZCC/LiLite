import Foundation

enum PresentationMode: String, CaseIterable {
  case system
  case audio
  case resample = "display-resample"
  case resampleDrop = "display-resample-vdrop"
  case resampleFree = "display-resample-desync"
  case tempo = "display-tempo"
  case videoDrop = "display-vdrop"
  case audioDrop = "display-adrop"
  case displayFree = "display-desync"
  case free = "desync"
  var display: Bool { self != .system && self != .audio && self != .free }
  var resamples: Bool { self == .resample || self == .resampleDrop || self == .resampleFree }
  static let modeKey = "play.videoSync", smoothingKey = "play.autosync"
  static var current: Self {
    Self(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .system
  }
  static func validSmoothing(_ s: String) -> Int? {
    guard !s.isEmpty, s.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(s),
      (0...10000).contains(n)
    else { return nil }
    return n
  }
  static var smoothing: Int {
    validSmoothing(UserDefaults.standard.string(forKey: smoothingKey) ?? "") ?? 0
  }
}
enum ClockAudioStep { case steady, drop, repeatLast }
/// HLS can announce a time jump on a continuous timeline. Only a real displacement needs
/// to tear down the independent renderer; never discard buffered PCM for a timestamp adjustment.
struct PlaybackDiscontinuity {
  private var sample: (media: Double, host: Double, rate: Double)?
  mutating func record(_ media: Double, host: Double, rate: Double) {
    guard media.isFinite, host.isFinite, rate.isFinite else { return }
    sample = (media, host, rate)
  }
  mutating func jumped(to media: Double, host: Double, rate: Double) -> Bool {
    guard media.isFinite, host.isFinite else { return false }
    defer { record(media, host: host, rate: rate) }
    guard let sample, (0...1).contains(host - sample.host) else { return true }
    return abs(media - (sample.media + (host - sample.host) * sample.rate)) > 0.15
  }
}
struct ClockStep {
  let video: Double, videoRate: Double, audioRate: Double, block: ClockAudioStep
  let phaseError: Double
}
enum ClockPicturePolicy {
  static func tolerance(fps: Double) -> Double {
    fps.isFinite && fps > 0 ? max(0.35, min(300, 1.5 / fps)) : 0.35
  }
  static func staleAfter(fps: Double) -> Double {
    fps.isFinite && fps > 0 ? max(1, min(300, 3 / fps)) : 1
  }
}
/// A presentation clock advances once per physical display callback. Its two rates are applied
/// independently at the picture decoder and the native audio renderer. Source PTS are never rewritten.
struct PresentationClock {
  var mode: PresentationMode
  let smoothing: Int
  private(set) var displayHz: Double = 60
  private var last: Double?, position = 0.0, phase = 0.0, audioEstimate: Double?, lastEstimate = 0.0
  private var lastBlock = -Double.greatestFiniteMagnitude,
    lastVideo = -Double.greatestFiniteMagnitude, drift = 0.0
  init(_ mode: PresentationMode, smoothing: Int) {
    self.mode = mode
    self.smoothing = max(0, smoothing)
  }
  mutating func reset(media: Double, host: Double) {
    last = host
    position = media
    phase = 0
    audioEstimate = nil
    lastEstimate = host
    drift = 0
    lastVideo = -Double.greatestFiniteMagnitude
    lastBlock = -Double.greatestFiniteMagnitude
  }
  static func displayFactor(hz: Double, fps: Double, rate: Double) -> Double {
    guard hz.isFinite, (20...250).contains(hz), fps.isFinite, (5...240).contains(fps),
      rate.isFinite, rate > 0
    else { return 1 }
    let ratio = hz / (fps * rate)
    for n in 1...5 {
      let nearest = (ratio * Double(n)).rounded()
      guard nearest > 0 else { continue }
      let factor = ratio * Double(n) / nearest
      if abs(factor - 1) <= 0.01 { return factor }
    }
    return 1
  }
  mutating func tick(
    host: Double, refresh: Double, fps: Double, rate: Double, audio: Double?, blockSeconds: Double,
    allowBlock: Bool = true
  ) -> ClockStep {
    let elapsed = max(0, host - (last ?? host))
    let dt = min(0.25, elapsed)
    last = host
    if refresh.isFinite, refresh >= 1 / 250.0, refresh <= 1 / 20.0 {
      let sample = 1 / refresh
      displayHz =
        abs(displayHz - sample) > 8 ? sample : displayHz + (sample - displayHz) * min(1, dt * 4)
    }
    let speed = rate.isFinite && rate > 0 ? rate : 1
    let fpsOK = fps.isFinite && fps >= 5 && fps <= 240
    let frame = fpsOK ? 1 / fps : 1 / 30.0
    let factor = mode.display ? Self.displayFactor(hz: displayHz, fps: fps, rate: speed) : 1
    let pictureRate = speed * factor
    // Control smoothing is bounded; media time must still include a delayed UI callback's
    // entire elapsed interval while the independent audio device continues rendering.
    position += elapsed * pictureRate
    var measured = audio
    if let a = audio, a.isFinite {
      if smoothing > 0, mode == .audio, let old = audioEstimate {
        let predicted = old + (host - lastEstimate) * speed
        let d = a - predicted
        if abs(d) < 0.35 { measured = predicted + d / Double(smoothing) }
      }
      audioEstimate = measured
      lastEstimate = host
    } else {
      measured = nil
    }
    var time = position + phase
    var sound = speed
    var step = ClockAudioStep.steady
    let err = measured.map { $0 - time } ?? 0
    switch mode {
    case .audio: if let measured { time = measured }
    case .resample, .tempo:
      // Drift correction is deliberately slower than source-rate matching; transient jitter must
      // not turn into audible wow. A positive error means the sound is ahead.
      drift += (err - drift) * min(1, dt / 0.45)
      sound = pictureRate * min(1.00125, max(0.99875, 1 - drift / 3))
    case .resampleDrop, .videoDrop:
      sound = mode == .resampleDrop ? pictureRate : speed
      if measured != nil, abs(err) > frame * 0.75 {
        let adjust = min(3, max(-3, (err / frame).rounded())) * frame
        phase += adjust
        time = position + phase
      }
    case .resampleFree: sound = pictureRate
    case .audioDrop:
      let block = max(1 / 192000.0, min(0.2, blockSeconds))
      if allowBlock, measured != nil, abs(err) > block * 0.85,
        host - lastBlock > max(0.06, block * 2)
      {
        step = err > 0 ? .repeatLast : .drop
        lastBlock = host
      }
    case .system, .displayFree, .free: break
    }
    time = max(lastVideo, time)
    lastVideo = time
    return .init(
      video: time, videoRate: pictureRate, audioRate: sound, block: step, phaseError: err)
  }
}
