import Foundation

/// A window belongs to exactly one AV asset / DASH representation. Audio and video have separate
/// byte offsets but share the two budgets. Never keep URLs or authentication material here.
actor MediaBufferWindow {
  typealias Fetch = @Sendable (Int64, Int64) async throws -> Data
  private struct Part {
    let lane: Int, start: Int64, data: Data
    var end: Int64 { start + Int64(data.count) }
    func piece(_ a: Int64, _ b: Int64) -> Data {
      if a == start && b == end { return data }
      return data.subdata(in: data.startIndex + Int(a - start)..<data.startIndex + Int(b - start))
    }
  }
  private struct Waiter {
    let id: UUID, lane: Int, wake: CheckedContinuation<Void, Error>
  }
  private var history: [Part] = [], forward: [Part] = [], busy = Set<Int>(), waiting: [Waiter] = []
  private var stopped = false, generation: UInt64 = 0, reducedUntil: TimeInterval = 0
  private struct Forecast { let id: UUID, start: Int64, end: Int64, task: Task<Void, Never> }
  private var forecasts: [Int: Forecast] = [:], lanes = Set<Int>()
  private let normal: Int
  init(capacity: Int) { normal = max(0, capacity) }
  private var cap: Int {
    ProcessInfo.processInfo.systemUptime < reducedUntil ? min(normal, 256 * 1024) : normal
  }
  var usage: (behind: Int, ahead: Int) {
    (history.reduce(0) { $0 + $1.data.count }, forward.reduce(0) { $0 + $1.data.count })
  }
  func pressure() {
    reducedUntil = ProcessInfo.processInfo.systemUptime + 30
    purge()
  }
  private func purge() {
    forecasts.values.forEach { $0.task.cancel() }
    forecasts.removeAll()
    generation &+= 1
    history.removeAll(keepingCapacity: false)
    forward.removeAll(keepingCapacity: false)
  }
  func close() {
    stopped = true
    purge()
    let q = waiting
    waiting.removeAll()
    q.forEach { $0.wake.resume(throwing: CancellationError()) }
  }
  private func cancel(_ id: UUID) {
    guard let n = waiting.firstIndex(where: { $0.id == id }) else { return }
    waiting.remove(at: n).wake.resume(throwing: CancellationError())
  }
  private func acquire(_ lane: Int) async throws {
    try Task.checkCancellation()
    guard !stopped else { throw CancellationError() }
    if busy.insert(lane).inserted { return }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
        if Task.isCancelled || stopped {
          c.resume(throwing: CancellationError())
        } else {
          waiting.append(.init(id: id, lane: lane, wake: c))
        }
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }
  private func release(_ lane: Int) {
    if let n = waiting.firstIndex(where: { $0.lane == lane }) {
      waiting.remove(at: n).wake.resume()
    } else {
      busy.remove(lane)
    }
  }
  private static func remember(_ part: Part, in list: inout [Part], limit: Int, tail: Bool) {
    guard limit > 0, !part.data.isEmpty else { return }
    let start = tail ? max(part.start, part.end - Int64(limit)) : part.start
    let end = start + Int64(min(limit, part.data.count))
    let p = Part(lane: part.lane, start: start, data: part.piece(start, end))
    list.removeAll { $0.lane == p.lane && $0.start < p.end && p.start < $0.end }
    list.append(p)
    var n = list.reduce(0) { $0 + $1.data.count }
    while n > limit || list.count > 256 {
      let first = list.removeFirst()
      if list.count < 256 && n - first.data.count < limit {
        // Preserve the nearest end of the oldest history, or the beginning of future data.
        let keep = limit - (n - first.data.count)
        if keep > 0 && keep < first.data.count {
          let lo = tail ? first.end - Int64(keep) : first.start
          list.insert(
            Part(lane: first.lane, start: lo, data: first.piece(lo, lo + Int64(keep))), at: 0)
          break
        }
      }
      n -= first.data.count
    }
  }
  private func cached(_ lane: Int, _ offset: Int64, _ end: Int64) -> Data? {
    let limit = cap
    if let i = forward.lastIndex(where: { $0.lane == lane && $0.start <= offset && offset < $0.end }
    ) {
      let part = forward.remove(at: i)
      let hi = min(part.end, end)
      if part.start < offset {
        Self.remember(
          .init(lane: lane, start: part.start, data: part.piece(part.start, offset)), in: &history,
          limit: limit, tail: true)
      }
      if hi < part.end {
        Self.remember(
          .init(lane: lane, start: hi, data: part.piece(hi, part.end)), in: &forward, limit: limit,
          tail: false)
      }
      let data = part.piece(offset, hi)
      Self.remember(
        .init(lane: lane, start: offset, data: data), in: &history, limit: limit, tail: true)
      return data
    }
    if let i = history.lastIndex(where: { $0.lane == lane && $0.start <= offset && offset < $0.end }
    ) {
      let part = history.remove(at: i)
      history.append(part)
      return part.piece(offset, min(end, part.end))
    }
    return nil
  }
  private func cancelForecast(_ lane: Int) {
    forecasts.removeValue(forKey: lane)?.task.cancel()
  }
  private func forecast(_ lane: Int, from start: Int64, mediaEnd: Int64, fetch: @escaping Fetch) {
    let share = cap / max(1, lanes.count)
    guard !stopped, share > 0, start <= mediaEnd,
      ProcessInfo.processInfo.systemUptime >= reducedUntil
    else { return }
    let end = start + min(Int64(share), mediaEnd + 1 - start)
    if let old = forecasts[lane], old.start <= start, old.end >= start,
      old.end - start >= (end - start) / 2
    {
      return
    }
    cancelForecast(lane)
    let id = UUID()
    let task = Task<Void, Never>(priority: .utility) { [weak self] in
      await self?.warm(lane, from: start, end: end, id: id, fetch: fetch)
    }
    forecasts[lane] = Forecast(id: id, start: start, end: end, task: task)
  }
  private func warm(_ lane: Int, from start: Int64, end: Int64, id: UUID, fetch: Fetch) async {
    guard forecasts[lane]?.id == id else { return }
    defer { if forecasts[lane]?.id == id { forecasts[lane] = nil } }
    let timeout = ProcessInfo.processInfo.systemUptime + 4
    var cursor = start
    while cursor < end && !Task.isCancelled && !stopped && forecasts[lane]?.id == id
      && ProcessInfo.processInfo.systemUptime < timeout
    {
      if let existing = forward.last(where: {
        $0.lane == lane && $0.start <= cursor && cursor < $0.end
      }) {
        cursor = existing.end
        continue
      }
      let next = forward.filter { $0.lane == lane && $0.start > cursor }.map(\.start).min() ?? end
      let hi = cursor + min(512 * 1024, min(next, end) - cursor)
      do {
        let data = try await fetch(cursor, hi - 1)
        guard !Task.isCancelled, !stopped, forecasts[lane]?.id == id, data.count == Int(hi - cursor)
        else { return }
        let limit = cap
        Self.remember(
          .init(lane: lane, start: cursor, data: data), in: &forward, limit: limit, tail: false)
        cursor = hi
      } catch { return }  // The next real read reports a real error or uses a listed backup.
    }
  }
  /// Inclusive request, caller-supplied final byte of this exact representation. Without a verified
  /// final byte (e.g. initial SIDX), fetch precisely what was requested, never speculate past EOF.
  func read(
    lane: Int, from first: Int64, through last: Int64, endOfMedia: Int64?, fetch: @escaping Fetch
  )
    async throws -> Data
  {
    let maxResponse = 48 * 1024 * 1024
    guard first >= 0, last >= first, last < Int64.max, last - first < Int64(maxResponse),
      endOfMedia.map({ $0 >= last && $0 < Int64.max }) ?? true
    else { throw URLError(.badURL) }
    try await acquire(lane)
    defer { release(lane) }
    lanes.insert(lane)
    let requestGeneration = generation
    if let flow = forecasts[lane], first < flow.start || first >= flow.end { cancelForecast(lane) }
    var result = Data()
    let end = last + 1
    result.reserveCapacity(Int(end - first))
    var cursor = first
    while cursor < end {
      try Task.checkCancellation()
      guard !stopped else { throw CancellationError() }
      if let saved = cached(lane, cursor, end) {
        result.append(saved)
        cursor += Int64(saved.count)
        continue
      }
      // Foreground reads win over speculative requests, including after a seek.
      cancelForecast(lane)
      let endDemand = cursor + min(end - cursor, 2 * 1024 * 1024)
      let gen = generation
      // Release the bytes AVPlayer is waiting for as soon as they arrive. Read-ahead is a
      // separate cancellable request; even a tiny audio fragment must not wait for 512 KiB more.
      let bytes = try await fetch(cursor, endDemand - 1)
      try Task.checkCancellation()
      guard !stopped else { throw CancellationError() }
      guard bytes.count == Int(endDemand - cursor) else { throw URLError(.networkConnectionLost) }
      if cursor == first && endDemand == end { result = bytes } else { result.append(bytes) }
      if gen == generation {
        let limit = cap
        Self.remember(
          .init(lane: lane, start: cursor, data: bytes), in: &history, limit: limit, tail: true)
      }
      cursor = endDemand
    }
    if let endOfMedia, end - first >= 4096, generation == requestGeneration {
      forecast(lane, from: end, mediaEnd: endOfMedia, fetch: fetch)
    }
    return result
  }
}

final class MediaBufferSession: @unchecked Sendable {
  let window: MediaBufferWindow
  private let pressure: MediaBufferPressure
  init(capacity: Int = MediaBufferPolicy.current(live: false)) {
    let window = MediaBufferWindow(capacity: capacity)
    self.window = window
    pressure = MediaBufferPressure { Task { await window.pressure() } }
  }
  func close() { Task { await window.close() } }
}
