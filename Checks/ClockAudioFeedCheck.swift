import CLiveRemux
import Foundation

enum DecoderProblem: Error { case unsupported, size }

private final class Parts: PictureTimingSource, @unchecked Sendable {
  let clockFPS: Double? = 24
  let count: Int, delay: UInt64, broken: Int?
  private let lock = NSLock()
  private var requests = 0, cancellations = 0
  init(count: Int = 80, delay: UInt64 = 12_000_000, broken: Int? = nil) {
    self.count = count; self.delay = delay; self.broken = broken
  }
  func clockIndex(at time: Double) -> Int? { Int(time * 4) * 7 }
  func nextClockIndex(after index: Int) async throws -> Int? { index + 7 < count * 7 ? index + 7 : nil }
  var stats: (Int, Int) { lock.withLock { (requests, cancellations) } }
  func clockPart(_ index: Int) async throws -> ClockAudioPart? {
    guard index >= 0, index % 7 == 0, index / 7 < count else { return nil }
    lock.withLock { requests += 1 }
    do { try await Task.sleep(nanoseconds: delay) }
    catch { lock.withLock { cancellations += 1 }; throw error }
    let first = index / 7 * 12000
    let samples: [Int32] = (first..<first + 12000).flatMap { frame in
      [Int32((frame % 1000) * 100000), -Int32((frame % 1000) * 100000)]
    }
    let bytes = samples.withUnsafeBytes { Data($0) }
    return .init(index: index, start: Double(first) / 48000 + (index == broken ? 2 : 0),
      pcm: .init(bytes: bytes, rate: 48000, channels: 2, frames: 12000,
        startSample: Int64(first), layout: [0, 1], videoStart: nil))
  }
}

@main enum ClockAudioFeedCheck {
  private static func blockUI(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
  @MainActor static func main() async throws {
    let source = Parts(), anchor = 0.125
    let first = try await source.clockPart(0)!
    let prepared = try await ClockAudioPrebuffer.prepare(first, source: source, at: anchor, speed: 1)
    precondition(prepared.parts.count == 3 && prepared.ready(at: anchor, speed: 1))
    let ring = try DeviceRing(rate: 48000, channels: 2, first: 6000)
    let feed = ClockAudioFeed(ring: ring, source: source, prepared: prepared, first: 6000, layout: [0, 1], speed: 1)
    try await feed.prime(frames: 24000)
    let requestsBefore = source.stats.0
    let consumer = Task.detached { () throws -> Int in
      var left = [Float](repeating: 0, count: 800), right = left, consumed = 0
      for tick in 0..<270 {
        let n = left.withUnsafeMutableBufferPointer { l in
          right.withUnsafeMutableBufferPointer { r in
            var planes = [l.baseAddress, r.baseAddress]
            return planes.withUnsafeMutableBufferPointer {
              pl_clock_render(ring.value, 800, $0.baseAddress, Double(tick) / 60)
            }
          }
        }
        precondition(n == 800, "producer starved while the UI actor was blocked")
        for j in 0..<800 {
          let expected = Double((6000 + consumed + j) % 1000) * 100000 / 2147483648
          precondition(abs(Double(left[j]) - expected) < 0.0000001 && left[j] == -right[j])
        }
        consumed += 800
        precondition(pl_clock_time(ring.value, Double(tick + 1) / 60, 1, 0).isFinite)
        try await Task.sleep(nanoseconds: 16_666_667)
      }
      return consumed
    }
    blockUI(4.6)
    let consumed = try await consumer.value
    precondition(consumed == 216000 && source.stats.0 > requestsBefore && !feed.snapshot.failed)
    feed.cancel(); await feed.waitForStop()
    let stopped = source.stats.0
    try await Task.sleep(nanoseconds: 30_000_000)
    precondition(source.stats.0 == stopped)
    print("Detached supply: UI actor blocked 4.6 s, 270 stereo callbacks, 216000 exact frames, zero underruns; cancellation stopped requests")

    let short = Parts(count: 1)
    let tail = try await ClockAudioPrebuffer.prepare(short.clockPart(0)!, source: short, at: 0.2, speed: 2)
    precondition(tail.ended && tail.ready(at: 0.2, speed: 2))
    let tailRing = try DeviceRing(rate: 48000, channels: 2, first: 9600)
    let tailFeed = ClockAudioFeed(ring: tailRing, source: short, prepared: tail, first: 9600, layout: [0, 1], speed: 2)
    try await tailFeed.prime(frames: 24000)
    precondition(tailRing.buffered == 2400 && tailFeed.snapshot.ended)
    tailFeed.cancel(); await tailFeed.waitForStop()

    let bad = Parts(broken: 7)
    let badRing = try DeviceRing(rate: 48000, channels: 2, first: 0)
    let badFeed = ClockAudioFeed(ring: badRing, source: bad,
      prepared: .init(parts: [first], ended: false), first: 0, layout: [0, 1], speed: 1)
    do { try await badFeed.prime(frames: 24000); fatalError("discontinuity accepted") }
    catch ClockFeedProblem.format { precondition(badFeed.snapshot.failed) }
    badFeed.cancel(); await badFeed.waitForStop()

    let slow = Parts(delay: 5_000_000_000)
    let slowRing = try DeviceRing(rate: 48000, channels: 2, first: 0)
    let slowFeed = ClockAudioFeed(ring: slowRing, source: slow,
      prepared: .init(parts: [first], ended: false), first: 0, layout: [0, 1], speed: 1)
    for _ in 0..<100 where slow.stats.0 == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
    precondition(slow.stats.0 == 1)
    slowFeed.cancel(); await slowFeed.waitForStop()
    precondition(slow.stats.1 == 1 && !slowFeed.snapshot.failed)
    do { try await slowFeed.prime(frames: 24000); fatalError("cancelled feed primed") }
    catch is CancellationError {}
    precondition(ClockAudioSupply.handoff(anchor: 10, current: 10.04, speed: 1))
    precondition(!ClockAudioSupply.handoff(anchor: 10, current: 10.2, speed: 1))
    precondition(!ClockAudioSupply.handoff(anchor: 10, current: 9, speed: 1))
    print("Short EOF reserve, nonconsecutive fragment IDs, rejected discontinuity, in-flight cancellation and handoff drift passed")
  }
}
