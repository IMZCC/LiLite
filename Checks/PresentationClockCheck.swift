import CLiveRemux
import Foundation

@main enum TimingCheck {
  static func main() throws {
    let pts = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(
      separator: "\n"
    ).map { Double($0)! }
    let samples = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let data = samples.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
    precondition(pts.count >= 160 && data.count >= 48000)
    let fps = 24000.0 / 1001.0
    var continuity = PlaybackDiscontinuity()
    continuity.record(5, host: 100, rate: 2)
    precondition(!continuity.jumped(to: 5.22, host: 100.1, rate: 2))
    precondition(continuity.jumped(to: 40, host: 100.2, rate: 0))
    precondition(!continuity.jumped(to: 40, host: 100.5, rate: 0))
    precondition(continuity.jumped(to: 2, host: 100.6, rate: 1))
    precondition(ClockPicturePolicy.tolerance(fps: 0.5) == 3)
    precondition(ClockPicturePolicy.staleAfter(fps: 0.5) == 6)
    var delayed = PresentationClock(.free, smoothing: 0)
    delayed.reset(media: 10, host: 100)
    let resumed = delayed.tick(host: 101.4, refresh: 1 / 60, fps: fps, rate: 2,
      audio: nil, blockSeconds: 1024 / 48000)
    precondition(abs(resumed.video - 12.8) < 0.000001)
    func position(_ t: Double) -> Int { pts.lastIndex(where: { $0 <= t + 0.0000001 }) ?? 0 }
    var clock = PresentationClock(.resampleFree, smoothing: 0)
    clock.reset(media: 0, host: 0)
    var seen = [Int: Int]()
    var expected = 0.0
    for i in 0..<361 {
      let s = clock.tick(
        host: Double(i) / 60, refresh: 1 / 60, fps: fps, rate: 1, audio: nil,
        blockSeconds: 1024 / 48000)
      seen[position(s.video), default: 0] += 1
      expected = s.videoRate
    }
    precondition(abs(expected - 1.001) < 0.000001)
    for id in 1..<143 { precondition([2, 3].contains(seen[id] ?? 0)) }
    print(
      "23.976 fps source → 60 Hz: 143 consecutive frame intervals showed 2 or 3 vsyncs, rate \(expected)"
    )
    clock.reset(media: 2.46, host: 10)
    var frameIndex = 0
    for i in 0...60 {
      let s = clock.tick(
        host: 10 + Double(i) / 60, refresh: 1 / 60, fps: fps, rate: 2, audio: nil,
        blockSeconds: 1024 / 48000)
      frameIndex = position(s.video)
      precondition(abs(s.videoRate - 2.002) < 0.000001)
    }
    precondition(frameIndex == position(2.46 + 2.002))
    print("Backwards seek to 2.460 s then 2×: selected original frame \(frameIndex)")
    func jitter(_ n: Int) -> Double {
      var cl = PresentationClock(.audio, smoothing: n)
      cl.reset(media: 0, host: 0)
      var errors = 0.0
      for i in 0...359 {
        let t = Double(i) / 60
        let a = t + (i % 2 == 0 ? 0.007 : -0.007)
        let s = cl.tick(
          host: t, refresh: 1 / 60, fps: fps, rate: 1, audio: a, blockSeconds: 1024 / 48000)
        if i >= 60 { errors += pow(s.video - t, 2) }
      }
      return sqrt(errors / 300)
    }
    let raw = jitter(0)
    let smoothed = jitter(30)
    precondition(smoothed < raw * 0.08)
    print(
      String(
        format: "Audio report jitter RMS %.3f → %.3f ms (0 vs 30)", raw * 1000, smoothed * 1000))
    for mode in PresentationMode.allCases where mode != .system {
      // Both clock components drive the same production ring as the AVAudioSourceNode callback.
      let rate = 48000
      let capacity = rate * 2
      let ring = pl_clock_ring(48000, 1, Int32(capacity), 0)!
      defer { pl_clock_destroy(ring) }
      var cl = PresentationClock(mode, smoothing: 0)
      cl.reset(media: 0, host: 0)
      var written = 0
      var aud = 0.0
      var magnitude = 0.0
      var commands = 0
      var last = 0.0
      var soundRate = 0.0
      var discontinuities = 0
      var plane = [Float](repeating: 0, count: 800)
      for i in 1...360 {
        let time = Double(i) / 60
        while pl_clock_buffered(ring) < 2400 {
          let start = written % data.count
          let n = data.withUnsafeBufferPointer {
            pl_clock_write(
              ring, $0.baseAddress!.advanced(by: start), Int32(min(1800, data.count - start)))
          }
          precondition(n > 0)
          written += Int(n)
        }
        let n = plane.withUnsafeMutableBufferPointer { out in
          var p = out.baseAddress
          return pl_clock_render(ring, 800, &p, time - 1 / 60)
        }
        precondition(n == 800)
        magnitude += abs(Double(plane[70]))
        aud = pl_clock_time(ring, time, 1, 0)
        precondition(aud.isFinite)
        if i == 1 { last = aud }
        if abs((aud - last) - 1 / 60) > 0.01 && i > 1 { discontinuities += 1 }
        last = aud
        // Inject a device latency mismatch so correction paths, not just enum names, run.
        let measured = aud - (i > 90 ? 0.048 : 0)
        let s = cl.tick(
          host: time, refresh: 1 / 60, fps: fps, rate: 1, audio: measured,
          blockSeconds: 1024.0 / 48000)
        if s.block != .steady { commands += 1 }
        pl_clock_tempo(ring, mode == .tempo ? s.audioRate : 1)
        pl_clock_control(
          ring, mode.resamples ? s.audioRate : 1,
          s.block == .drop ? 1 : s.block == .repeatLast ? -1 : 0)
        if mode == .audio { precondition(abs(s.video - measured) < 0.04) }
        soundRate = s.audioRate
      }
      if mode == .audioDrop { precondition(commands >= 2 && discontinuities >= 2) }
      if mode == .resample || mode == .tempo { precondition(soundRate > 1.001) }
      if mode == .resampleFree { precondition(abs(soundRate - 1.001) < 0.000001) }
      precondition(magnitude > 5)
      print(
        String(
          format: "%-23@ audio %.6f, real PCM block adjustments %d", mode.rawValue as NSString,
          soundRate, discontinuities))
    }
  }
}
