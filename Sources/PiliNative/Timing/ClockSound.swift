import AVFoundation
import CLiveRemux

// All engine and pitch-unit changes run on the main actor. The source render block only copies
// PCM into the device's buffers, publishes its hardware host timestamp, and never allocates.
@MainActor final class ClockSound {
  private let engine = AVAudioEngine(), pitch: AVAudioUnitTimePitch?
  private let node: AVAudioSourceNode, ring: DeviceRing
  private var audibleRate = 1.0, latency = 0.0
  private var feed: ClockAudioFeed?, lastLevel: Float = 0, feedSpeed = 1.0, started = false
  let rate: Int, layout: [Int32]
  private(set) var next: Int64
  var buffered: Int { Int(pl_clock_buffered(ring.value)) }
  var room: Int { Int(pl_clock_available(ring.value)) }
  var supply: ClockAudioFeed.Snapshot? { feed?.snapshot }
  static func commonSpeed(_ s: Double) -> Bool { (0.46...2.52).contains(s) }
  func canRun(_ speed: Double) -> Bool { Self.commonSpeed(speed) == (pitch == nil) }
  init(pcm: ClockPCM, at time: Double, speed: Double) throws {
    guard time.isFinite, time >= 0, time < 1e9 else { throw DecoderProblem.unsupported }
    rate = pcm.rate
    layout = pcm.layout
    next = Int64((time * Double(rate)).rounded())
    let ring = try DeviceRing(rate: rate, channels: pcm.channels, first: next)
    self.ring = ring
    guard
      let cl = pcm.layout.withUnsafeBufferPointer({
        pl_clock_audio_layout($0.baseAddress, Int32($0.count))
      })
    else { throw DecoderProblem.unsupported }
    defer { pl_clock_free_layout(cl) }
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), interleaved: false,
      channelLayout: AVAudioChannelLayout(layout: cl))
    let unit = AVAudioTime.seconds(forHostTime: 1_000_000_000) / 1_000_000_000
    node = AVAudioSourceNode(format: format) { silent, stamp, count, out in
      let n = pl_clock_render_abl(
        ring.value, Int32(count), out, Double(stamp.pointee.mHostTime) * unit)
      silent.pointee = ObjCBool(n == 0)
      return noErr
    }
    pitch = Self.commonSpeed(speed) ? nil : AVAudioUnitTimePitch()
    engine.attach(node)
    if let pitch {
      engine.attach(pitch)
      engine.connect(node, to: pitch, format: format)
      engine.connect(pitch, to: engine.mainMixerNode, format: format)
    } else {
      engine.connect(node, to: engine.mainMixerNode, format: format)
    }
    engine.mainMixerNode.outputVolume = 0
  }
  func start() throws {
    guard engine.outputNode.inputFormat(forBus: 0).sampleRate > 0 else {
      throw DecoderProblem.unsupported
    }
    engine.prepare()
    try engine.start()
    started = true
    latency = node.outputPresentationLatency
  }
  func prime(_ prepared: ClockAudioPrebuffer, source: any PictureTimingSource, speed: Double) async throws {
    guard feed == nil else { throw ClockFeedProblem.startup }
    let feed = ClockAudioFeed(ring: ring, source: source, prepared: prepared, first: next, layout: layout, speed: speed)
    self.feed = feed; feedSpeed = speed
    try await feed.prime(frames: ClockAudioSupply.startup(rate: rate, channels: layout.count, speed: speed))
  }
  func stop() { feed?.cancel(); feed = nil; started = false; engine.stop() }
  func configurationStopped(_ object: Any?) -> Bool {
    (object as AnyObject?) === engine && started && !engine.isRunning
  }
  func level(_ level: Float) {
    let value = min(1, max(0, level))
    if lastLevel != value { lastLevel = value; engine.mainMixerNode.outputVolume = value }
  }
  func now(_ host: Double) -> Double? {
    let s = pl_clock_time(ring.value, host, audibleRate, latency)
    return s.isFinite ? s : nil
  }
  func rates(_ step: ClockStep, mode: PresentationMode, speed: Double) {
    if abs(speed - feedSpeed) > 0.00001 { feedSpeed = speed; feed?.speed(speed) }
    let target = mode == .tempo ? step.audioRate : speed
    // AVAudioUnitTimePitch documents this 1/32...32 range. The caller uses AVKit outside it.
    if let pitch {
      if abs(Double(pitch.rate) - target) > 0.00002 { pitch.rate = Float(target) }
    } else {
      pl_clock_tempo(ring.value, target)
    }
    let r = mode.resamples ? step.audioRate / speed : 1
    let block: Int32 = step.block == .drop ? 1 : step.block == .repeatLast ? -1 : 0
    pl_clock_control(ring.value, r, block)
    audibleRate = target * r
  }
}
