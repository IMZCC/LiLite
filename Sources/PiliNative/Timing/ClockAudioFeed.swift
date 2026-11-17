import CLiveRemux
import Foundation

enum ClockFeedProblem: Error { case format, discontinuity, startup, lateStart }

enum ClockAudioSupply {
  static func capacity(rate: Int, channels: Int) -> Int {
    min(rate * 8, 16 * 1024 * 1024 / (4 * max(1, channels)))
  }
  static func startup(rate: Int, channels: Int, speed: Double) -> Int {
    min(max(1, (capacity(rate: rate, channels: channels) - 2048) / 2),
      max(rate / 2, Int(Double(rate) * min(32, max(0.03125, speed)) * 0.5)))
  }
  static func target(rate: Int, channels: Int, speed: Double) -> Int {
    min(max(1, capacity(rate: rate, channels: channels) - 2048),
      max(rate * 3, Int(Double(rate) * min(32, max(0.03125, speed)) * 3)))
  }
  static func handoff(anchor: Double, current: Double, speed: Double) -> Bool {
    anchor.isFinite && current.isFinite && current >= anchor - 0.02
      && current - anchor <= min(0.6, max(0.04, speed * 0.08))
  }
}

final class DeviceRing: @unchecked Sendable {
  let value: OpaquePointer, rate: Int, channels: Int
  init(rate: Int, channels: Int, first: Int64) throws {
    guard (8000...192000).contains(rate), (1...8).contains(channels), first >= 0 else { throw ClockFeedProblem.format }
    self.rate = rate; self.channels = channels
    guard let p = pl_clock_ring(Int32(rate), Int32(channels),
      Int32(ClockAudioSupply.capacity(rate: rate, channels: channels)), first) else { throw ClockFeedProblem.format }
    value = p
  }
  deinit { pl_clock_destroy(value) }
  var buffered: Int { Int(pl_clock_buffered(value)) }
}

/// Decode startup reserve before fixing a ring epoch. AVKit remains audible during this work.
struct ClockAudioPrebuffer: Sendable {
  let parts: [ClockAudioPart], ended: Bool
  var end: Double { parts.last.map { $0.start + $0.pcm.duration } ?? 0 }
  func ready(at time: Double, speed: Double) -> Bool {
    guard let first = parts.first, time.isFinite, end > time else { return false }
    return ended || end - time >= Double(ClockAudioSupply.startup(rate: first.pcm.rate,
      channels: first.pcm.channels, speed: speed)) / Double(first.pcm.rate)
  }
  static func prepare(_ first: ClockAudioPart, source: any PictureTimingSource,
    at time: Double, speed: Double) async throws -> Self {
    var parts = [first], ended = false, bytes = first.pcm.bytes.count
    while !Self(parts: parts, ended: ended).ready(at: time, speed: speed) {
      try Task.checkCancellation()
      guard parts.count < 16, bytes <= 64 * 1024 * 1024 else { throw ClockFeedProblem.startup }
      guard let cursor = try await source.nextClockIndex(after: parts.last!.index),
        let next = try await source.clockPart(cursor) else { ended = true; break }
      try Task.checkCancellation()
      guard next.index == cursor, cursor != parts.last!.index, next.pcm.rate == first.pcm.rate,
        next.pcm.layout == first.pcm.layout, next.start.isFinite, next.pcm.frames > 0,
        bytes <= 64 * 1024 * 1024 - next.pcm.bytes.count else { throw ClockFeedProblem.format }
      parts.append(next); bytes += next.pcm.bytes.count
    }
    return .init(parts: parts, ended: ended)
  }
}

/// Exactly one detached producer owns all writes. The device callback is the sole consumer.
/// Neither its progress nor its look-ahead depends on SwiftUI / CADisplayLink callbacks.
final class ClockAudioFeed: @unchecked Sendable {
  struct Snapshot: Sendable { let index: Int, ended: Bool, failed: Bool }
  private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var index: Int, ended = false, failed = false, speed: Double
    init(index: Int, speed: Double) { self.index = index; self.speed = speed }
    func snapshot() -> Snapshot { lock.withLock { .init(index: index, ended: ended, failed: failed) } }
    func update(index: Int? = nil, ended: Bool = false, failed: Bool = false) {
      lock.withLock { if let index { self.index = index }; self.ended = ended; self.failed = failed }
    }
    func speed(_ value: Double? = nil) -> Double {
      lock.withLock { if let value { speed = value }; return speed }
    }
  }
  private let state: State, work: Task<Void, Never>
  private let ring: DeviceRing
  var snapshot: Snapshot { state.snapshot() }
  init(ring: DeviceRing, source: any PictureTimingSource, prepared: ClockAudioPrebuffer,
    first: Int64, layout: [Int32], speed: Double) {
    self.ring = ring
    let state = State(index: prepared.parts.first?.index ?? 0, speed: speed)
    self.state = state
    work = Task.detached(priority: .userInitiated) {
      do {
        var queue = prepared.parts, next = first
        var index = queue.first?.index ?? 0, ended = prepared.ended
        while !Task.isCancelled {
          if queue.isEmpty {
            if ended { state.update(index: index, ended: true); return }
            let target = ClockAudioSupply.target(rate: ring.rate, channels: ring.channels, speed: state.speed())
            if ring.buffered >= target { try await Task.sleep(nanoseconds: 10_000_000); continue }
            guard let part = try await source.clockPart(index) else { ended = true; continue }
            try Task.checkCancellation()
            guard part.index == index else { throw ClockFeedProblem.discontinuity }
            queue = [part]
          }
          try Task.checkCancellation()
          let part = queue[0], pcm = part.pcm
          guard pcm.rate == ring.rate, pcm.channels == ring.channels, pcm.layout == layout,
            pcm.frames > 0, pcm.frames <= 48 * 1024 * 1024 / (4 * ring.channels),
            pcm.bytes.count == pcm.frames * ring.channels * 4, part.start.isFinite,
            abs(part.start) < 1e9 else { throw ClockFeedProblem.format }
          let first = Int64((part.start * Double(ring.rate)).rounded()), end = first + Int64(pcm.frames)
          if next >= end {
            queue.removeFirst()
            if let following = queue.first { index = following.index }
            else if let following = try await source.nextClockIndex(after: part.index) { index = following }
            else { ended = true }
            state.update(index: index)
            continue
          }
          if first > next {
            guard first - next <= ring.rate else { throw ClockFeedProblem.discontinuity }
            next += Int64(pl_clock_write(ring.value, nil, Int32(first - next)))
            if next < first { try await Task.sleep(nanoseconds: 5_000_000); continue }
          }
          try Task.checkCancellation()
          let skip = Int(next - first)
          let written = pcm.bytes.withUnsafeBytes {
            pl_clock_write(ring.value, $0.baseAddress?.advanced(by: skip * ring.channels * 4), Int32(pcm.frames - skip))
          }
          next += Int64(written)
          if next >= end {
            queue.removeFirst()
            if let following = queue.first { index = following.index }
            else if let following = try await source.nextClockIndex(after: part.index) { index = following }
            else { ended = true }
            state.update(index: index)
          }
          else { try await Task.sleep(nanoseconds: 5_000_000) }
        }
      } catch is CancellationError { }
      catch { if !Task.isCancelled { state.update(failed: true) } }
    }
  }
  func speed(_ value: Double) { _ = state.speed(value) }
  func cancel() { work.cancel() }
  func waitForStop() async { await work.value }
  func prime(frames: Int) async throws {
    while ring.buffered < frames {
      try Task.checkCancellation()
      guard !work.isCancelled else { throw CancellationError() }
      let status = snapshot
      if status.failed { throw ClockFeedProblem.format }
      if status.ended { guard ring.buffered > 0 else { throw ClockFeedProblem.startup }; return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
  }
  deinit { work.cancel() }
}
