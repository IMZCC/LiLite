import Foundation

@main enum MediaBufferCheck {
  actor Journal {
    var calls: [ClosedRange<Int64>] = []
    func bytes(_ a: Int64, _ b: Int64) -> Data {
      calls.append(a...b)
      return Data((a...b).map { UInt8($0 % 251) })
    }
  }
  actor Pause {
    var entered = false
    var waiting: CheckedContinuation<Void, Never>?
    func fetch(_ a: Int64, _ b: Int64) async -> Data {
      entered = true
      await withCheckedContinuation { waiting = $0 }
      return Data(repeating: 3, count: Int(b - a + 1))
    }
    func resume() {
      waiting?.resume()
      waiting = nil
    }
  }
  static func check(_ actual: Data, _ range: ClosedRange<Int64>) {
    precondition(actual == Data(range.map { UInt8($0 % 251) }))
  }
  static func fifo() {
    var pipe = MediaBufferFIFO()
    var first = 0
    let data = (0..<190_213).map { UInt8($0 % 251) }
    var out = [UInt8](repeating: 0, count: data.count)
    var offset = 0
    while offset < data.count {
      let window = offset > 60_000 ? 27_000 : 80_000
      let consumed = data.withUnsafeBytes { p in
        pipe.append(
          p.baseAddress!.advanced(by: offset), length: min(19_861, data.count - offset),
          limit: window)
      }
      offset += consumed
      if pipe.count > 20_000 || consumed == 0 {
        let n = out.withUnsafeMutableBufferPointer { p in
          pipe.take(p.baseAddress!.advanced(by: first), length: 13_379)
        }
        precondition(n > 0)
        first += n
      }
    }
    let left = out.withUnsafeMutableBufferPointer { p in
      pipe.take(p.baseAddress!.advanced(by: first), length: data.count - first)
    }
    precondition(first + left == data.count && pipe.count == 0 && data == out)
  }
  static func main() async throws {
    let mib = MediaBufferPolicy.mib
    let ram: UInt64 = 4 * 1024 * 1024 * 1024
    precondition(
      MediaBufferPolicy.capacity(live: false, vod: 4, override: 0, physical: ram) == 4 * mib)
    precondition(
      MediaBufferPolicy.capacity(live: true, vod: 4, override: 0, physical: ram) == 8 * mib)
    precondition(
      MediaBufferPolicy.capacity(live: true, vod: 4, override: 1.25, physical: ram) == 5 * mib / 4)
    precondition(
      MediaBufferPolicy.liveSeconds(capacity: mib, bitsPerSecond: Double(mib * 2), limit: 2) == 2)
    precondition(
      MediaBufferPolicy.horizon(after: 45, end: 100, bitsPerSecond: 16, seconds: 5) == 55)
    fifo()
    let window = MediaBufferWindow(capacity: 32)
    let server = Journal()
    let fetch: MediaBufferWindow.Fetch = { a, b in await server.bytes(a, b) }
    check(
      try await window.read(lane: 0, from: 8, through: 15, endOfMedia: 70, fetch: fetch), 8...15)
    check(
      try await window.read(lane: 0, from: 20, through: 25, endOfMedia: 70, fetch: fetch), 20...25)
    check(
      try await window.read(lane: 0, from: 8, through: 15, endOfMedia: 70, fetch: fetch), 8...15)
    let queries = await server.calls
    precondition(queries == [8...15, 20...25])
    let side = try await window.read(lane: 1, from: 8, through: 15, endOfMedia: nil) { a, b in
      Data(repeating: 22, count: Int(b - a + 1))
    }
    precondition(side == Data(repeating: 22, count: 8))
    let size = await window.usage
    precondition(size.ahead <= 32 && size.behind <= 32)
    do {
      _ = try await window.read(lane: 0, from: 99, through: 105, endOfMedia: nil) { _, _ in Data() }
      preconditionFailure("accepted short bytes")
    } catch {}
    let gate = Pause()
    let one = Task {
      try await window.read(lane: 0, from: 161, through: 181, endOfMedia: nil) { a, b in
        await gate.fetch(a, b)
      }
    }
    while !(await gate.entered) { await Task.yield() }
    let queued = Task {
      try await window.read(lane: 0, from: 162, through: 165, endOfMedia: nil, fetch: fetch)
    }
    queued.cancel()
    do {
      _ = try await queued.value
      preconditionFailure("queued seek ignored cancellation")
    } catch {}
    await window.pressure()
    await gate.resume()
    let preserved = try await one.value
    let cleared = await window.usage
    precondition(preserved.count == 21 && cleared.ahead == 0 && cleared.behind == 0)
    await window.close()
    do {
      _ = try await window.read(lane: 0, from: 0, through: 1, endOfMedia: nil, fetch: fetch)
      preconditionFailure("read after close")
    } catch {}
    let warm = MediaBufferWindow(capacity: mib)
    let fill: MediaBufferWindow.Fetch = { a, b in Data(repeating: 42, count: Int(b - a + 1)) }
    _ = try await warm.read(
      lane: 0, from: 0, through: 16383, endOfMedia: Int64(2 * mib), fetch: fill)
    for _ in 0..<120 {
      if await warm.usage.ahead == mib { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let warmed = await warm.usage
    precondition(warmed.ahead == mib && warmed.behind == 16384)
    let hit = try await warm.read(lane: 0, from: 730000, through: 730015, endOfMedia: nil) { _, _ in
      throw URLError(.notConnectedToInternet)
    }
    precondition(hit == Data(repeating: 42, count: 16))
    await warm.close()
    print(
      "Media buffer: two capacity budgets, actual read-ahead, backwards seek, A/V isolation, cancellation, memory pressure and live FIFO verified"
    )
  }
}
