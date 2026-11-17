import CLiveRemux
import Foundation

enum DecoderProblem: LocalizedError {
  case keyframe, unsupported, size
  var errorDescription: String? {
    switch self {
    case .keyframe: return "这里缺少可用的起始关键帧"
    case .unsupported: return "当前解码方式无法播放此视频片段"
    case .size: return "视频片段超出当前设备的处理范围"
    }
  }
}
enum DecoderSegment {
  static func convert(
    initial: Data, media: Data, source: Int64, target: Int64, index: Int, route: NativeVideoRoute
  ) async throws -> DecoderFragment {
    guard initial.count <= 4 * 1024 * 1024, media.count <= 48 * 1024 * 1024, route.converts else {
      throw DecoderProblem.size
    }
    let worker = Task.detached(priority: .userInitiated) { () throws -> (Data, Int32) in
      try Task.checkCancellation()
      var output: UnsafeMutablePointer<UInt8>?
      var size: Int32 = 0
      var stats = PLDecodedVideo()
      var diagnostic = [CChar](repeating: 0, count: 100)
      let pixels = Int32(
        min(
          UInt64(8192 * 4608),
          max(UInt64(1920 * 1080), ProcessInfo.processInfo.physicalMemory / 144)))
      let status = initial.withUnsafeBytes { prefix in
        media.withUnsafeBytes { payload in
          pl_decode_video(
            prefix.bindMemory(to: UInt8.self).baseAddress, Int32(initial.count),
            payload.bindMemory(to: UInt8.self).baseAddress, Int32(media.count), source, target,
            route == .copied ? Int32(PL_VT_COPY) : Int32(PL_SOFTWARE), pixels, 2, nil,
            { _ in Task.isCancelled ? 1 : 0 }, nil, &stats, &output, &size, &diagnostic, 100)
        }
      }
      guard status == 0, let output, size > 0, stats.frames > 0 else {
        if let output { pl_free_video(output) }
        try Task.checkCancellation()
        if status == Int32(PL_NEEDS_KEYFRAME) { throw DecoderProblem.keyframe }
        throw DecoderProblem.unsupported
      }
      let result = Data(
        bytesNoCopy: output, count: Int(size),
        deallocator: .custom { p, _ in
          pl_free_video(p.assumingMemoryBound(to: UInt8.self))
        })
      try Task.checkCancellation()
      return (result, stats.transfer)
    }
    let (bytes, transfer) = try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
    return try DecoderFragment(bytes, index: index, transfer: transfer)
  }
}

/// AVPlayer may inquire about size, range-read or seek concurrently. Coalesce demands by segment,
/// encode one at a time, and cancel the real worker when all interested connections go away.
actor DecoderSegments {
  typealias Make = @Sendable () async throws -> DecoderFragment
  private struct Job {
    let id: UUID, index: Int, make: Make
    var clients: [UUID: CheckedContinuation<DecoderFragment, Error>]
    var running: Task<Void, Never>?
  }
  private var order: [Int] = [], jobs: [Int: Job] = [:]
  private var recent: [(Int, DecoderFragment)] = []
  private var running: UUID?, stopped = false
  func load(_ index: Int, make: @escaping Make) async throws -> DecoderFragment {
    try Task.checkCancellation()
    guard !stopped else { throw CancellationError() }
    if let i = recent.firstIndex(where: { $0.0 == index }) {
      let hit = recent.remove(at: i)
      recent.append(hit)
      return hit.1
    }
    let client = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { con in
        guard !Task.isCancelled else {
          con.resume(throwing: CancellationError())
          return
        }
        if jobs[index] != nil {
          jobs[index]!.clients[client] = con
        } else {
          guard jobs.count < 32 else {
            con.resume(throwing: URLError(.resourceUnavailable))
            return
          }
          jobs[index] = Job(id: UUID(), index: index, make: make, clients: [client: con])
          order.append(index)
          schedule()
        }
      }
    } onCancel: {
      Task { await self.cancel(client: client, index: index) }
    }
  }
  private func schedule() {
    guard running == nil, !stopped else { return }
    while !order.isEmpty {
      let n = order.removeFirst()
      guard let job = jobs[n] else { continue }
      running = job.id
      jobs[n]!.running = Task {
        do {
          let d = try await job.make()
          self.finish(n, id: job.id, result: .success(d))
        } catch { self.finish(n, id: job.id, result: .failure(error)) }
      }
      break
    }
  }
  private func finish(_ n: Int, id: UUID, result: Result<DecoderFragment, Error>) {
    if running == id { running = nil }
    if jobs[n]?.id == id, let job = jobs.removeValue(forKey: n) {
      if case .success(let bytes) = result, !job.clients.isEmpty && !stopped {
        recent.append((n, bytes))
        while recent.count > 1
          && (recent.count > 3 || recent.reduce(0, { $0 + $1.1.count }) > 20 * 1024 * 1024)
        { recent.removeFirst() }
      }
      for (_, con) in job.clients { con.resume(with: result) }
    }
    schedule()
  }
  private func cancel(client: UUID, index: Int) {
    guard let con = jobs[index]?.clients.removeValue(forKey: client) else { return }
    con.resume(throwing: CancellationError())
    if jobs[index]?.clients.isEmpty == true { drop(index) }
  }
  private func drop(_ index: Int) {
    guard let job = jobs.removeValue(forKey: index) else { return }
    job.running?.cancel()
    order.removeAll { $0 == index }
    for (_, con) in job.clients { con.resume(throwing: CancellationError()) }
  }
  func seek(_ target: Int) {
    for n in Array(jobs.keys) where abs(n - target) > 1 { drop(n) }
  }
  func trim() { recent.removeAll() }
  func reset() {
    for n in Array(jobs.keys) { drop(n) }
    trim()
  }
  func stop() {
    stopped = true
    reset()
  }
}
