import Foundation

protocol LegacySliceResource: Sendable {
  func close()
  func cancelDemands()
}

actor LegacySlicePool<Resource: LegacySliceResource> {
  private var ready: [Int: (UUID, Resource)] = [:], pending: [Int: (UUID, Task<Resource, Error>)] = [:]
  private var order: [Int] = [], stopped = false
  private var readers: [Int: Int] = [:]
  #if PILI_SLICE_QA
  // Exposes the demand phase to the concurrency fixture without changing scheduling or results.
  func readerCount(_ n: Int) -> Int { readers[n] ?? 0 }
  #endif
  private func trim() {
    while ready.count > 3, let old = order.first(where: { (readers[$0] ?? 0) == 0 }) {
      order.removeAll { $0 == old }; ready.removeValue(forKey: old)?.1.close()
    }
  }
  func release(_ n: Int) { readers[n] = max(0, (readers[n] ?? 0) - 1); trim() }
  func get(_ n: Int, create: @escaping @Sendable () async throws -> Resource) async throws -> Resource {
    try Task.checkCancellation()
    guard !stopped else { throw CancellationError() }
    readers[n, default: 0] += 1
    if let (_, result) = ready[n] { order.removeAll { $0 == n }; order.append(n); return result }
    if let (stamp, task) = pending[n] {
      do {
        let result = try await task.value
        try Task.checkCancellation()
        guard !stopped, !task.isCancelled, pending[n]?.0 == stamp || ready[n]?.0 == stamp else { throw CancellationError() }
        return result
      } catch { release(n); throw error }
    }
    let stamp = UUID(), task = Task { try await create() }; pending[n] = (stamp, task)
    do {
      let value = try await task.value
      guard !stopped, !task.isCancelled, pending[n]?.0 == stamp else { value.close(); throw CancellationError() }
      if pending[n]?.0 == stamp { pending[n] = nil }
      ready[n] = (stamp, value); order.append(n); trim()
      try Task.checkCancellation()
      return value
    } catch { if pending[n]?.0 == stamp { pending[n] = nil }; release(n); throw error }
  }
  func seek(_ n: Int) {
    for key in Array(pending.keys) where abs(key - n) > 2 { pending.removeValue(forKey: key)?.1.cancel() }
    for (key, value) in ready where abs(key - n) > 2 { value.1.cancelDemands() }
  }
  func cancel() { pending.values.forEach { $0.1.cancel() }; pending.removeAll() }
  func stop() {
    stopped = true; cancel(); ready.values.forEach { $0.1.close() }; ready.removeAll(); order.removeAll()
  }
}
