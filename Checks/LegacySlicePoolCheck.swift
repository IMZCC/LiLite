import Foundation

private actor Gate {
  private var entered = false, opened = false
  private var waits: [CheckedContinuation<Void, Never>] = [], starts: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    entered = true; starts.forEach { $0.resume() }; starts.removeAll()
    if !opened { await withCheckedContinuation { waits.append($0) } }
  }
  func started() async { if !entered { await withCheckedContinuation { starts.append($0) } } }
  func open() { opened = true; waits.forEach { $0.resume() }; waits.removeAll() }
}
private final class Resource: LegacySliceResource, @unchecked Sendable {
  let id: Int
  private let lock = NSLock()
  private var count = 0
  init(_ id: Int) { self.id = id }
  func close() { lock.withLock { count += 1 } }
  func cancelDemands() {}
  var closes: Int { lock.withLock { count } }
}
@main enum LegacySlicePoolCheck {
  private static func joined(_ pool: LegacySlicePool<Resource>, _ n: Int) async throws {
    let limit = ContinuousClock.now + .seconds(3)
    while await pool.readerCount(n) < 2 {
      precondition(ContinuousClock.now < limit, "second waiter did not enter the production pool")
      try await Task.sleep(for: .milliseconds(1))
    }
  }
  static func cancelledWaiters(stop: Bool) async throws {
    let pool = LegacySlicePool<Resource>(), gate = Gate(), source = Resource(30)
    let creator = Task { try await pool.get(0) { await gate.wait(); return source } }
    await gate.started()
    let waiter = Task { try await pool.get(0) { preconditionFailure("duplicate cancellation fixture factory") } }
    try await joined(pool, 0)
    if stop { await pool.stop() } else { await pool.seek(30) }
    // The producer deliberately ignores cancellation until its external callback arrives.
    await gate.open()
    for task in [creator, waiter] {
      do { _ = try await task.value; preconditionFailure("cancelled creator or second waiter returned a resource") }
      catch is CancellationError {}
    }
    precondition(source.closes == 1, "cancelled resource must close exactly once")
    if !stop {
      let next = Resource(31)
      let current = try await pool.get(0) { next }
      precondition(current === next && current.closes == 0)
      await pool.release(0); await pool.stop(); precondition(next.closes == 1)
    }
  }
  static func cancelledCaller() async throws {
    let pool = LegacySlicePool<Resource>(), gate = Gate(), source = Resource(40)
    let creator = Task { try await pool.get(0) { await gate.wait(); return source } }
    await gate.started()
    let waiter = Task { try await pool.get(0) { preconditionFailure("cancelled caller duplicated work") } }
    try await joined(pool, 0)
    creator.cancel(); await gate.open()
    do { _ = try await creator.value; preconditionFailure("cancelled caller received media") } catch is CancellationError {}
    let current = try await waiter.value
    precondition(current === source && source.closes == 0, "one cancelled client closed a healthy shared resource")
    await pool.release(0); await pool.stop(); precondition(source.closes == 1)
  }
  static func main() async throws {
    try await cancelledWaiters(stop: true)
    try await cancelledWaiters(stop: false)
    try await cancelledCaller()
    let pool = LegacySlicePool<Resource>(), gate = Gate(), source = Resource(0)
    let one = Task { try await pool.get(0) { await gate.wait(); return source } }
    await gate.started()
    let two = Task { try await pool.get(0) { preconditionFailure("duplicate conversion") } }
    await gate.open()
    let a = try await one.value, b = try await two.value
    precondition(a === b)
    for n in 1...4 { _ = try await pool.get(n) { Resource(n) }; await pool.release(n) }
    precondition(source.closes == 0, "an in-use GOP was evicted")
    await pool.release(0); precondition(source.closes == 0)
    await pool.release(0)
    _ = try await pool.get(5) { Resource(5) }; await pool.release(5)
    precondition(source.closes == 1)
    let oldGate = Gate(), newGate = Gate(), stale = Resource(10), fresh = Resource(11)
    let old = Task { try await pool.get(10) { await oldGate.wait(); return stale } }
    await oldGate.started(); await pool.seek(30)
    let replacement = Task { try await pool.get(10) { await newGate.wait(); return fresh } }
    await newGate.started(); await oldGate.open()
    do { _ = try await old.value; preconditionFailure("cancelled conversion published") } catch {}
    let shared = Task { try await pool.get(10) { preconditionFailure("stale cleanup erased the replacement") } }
    await newGate.open()
    let current = try await replacement.value, same = try await shared.value
    precondition(current === fresh && same === fresh && stale.closes == 1)
    await pool.release(10); await pool.release(10)
    await pool.stop(); precondition(fresh.closes == 1)
    do { _ = try await pool.get(1) { Resource(1) }; preconditionFailure("closed pool reopened") } catch {}
    print("Legacy slice pool: coalesced requests, live leases, bounded eviction, both waiters cancelled by stop/seek, single caller cancellation, stale completion and replacement isolation passed")
  }
}
