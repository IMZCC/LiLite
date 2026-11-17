import Foundation

@main enum DecoderPlaybackCheck {
  actor Count {
    var value = 0
    func mark() { value += 1 }
  }
  static func main() async throws {
    let a = CommandLine.arguments
    let initial = try Data(contentsOf: URL(fileURLWithPath: a[1]))
    let media = try Data(contentsOf: URL(fileURLWithPath: a[2]))
    let offset = Int64(a[3])!
    let out = URL(fileURLWithPath: a[4])
    let pool = DecoderSegments()
    let count = Count()
    let build: DecoderSegments.Make = {
      await count.mark()
      return try await DecoderSegment.convert(
        initial: initial, media: media, source: offset, target: offset, index: 8, route: .software)
    }
    let all = try await withThrowingTaskGroup(of: DecoderFragment.self) { group in
      for _ in 0..<8 { group.addTask { try await pool.load(8, make: build) } }
      var values: [DecoderFragment] = []
      for try await clip in group { values.append(clip) }
      return values
    }
    let started = await count.value
    precondition(
      started == 1 && all.count == 8
        && all.allSatisfy { $0.initial == all[0].initial && $0.media == all[0].media })
    var ready = all[0].initial
    ready.append(all[0].media)
    try ready.write(to: out)
    let entered = Count()
    let stale = Task {
      try await pool.load(9) {
        await entered.mark()
        try await Task.sleep(for: .seconds(10))
        return all[0]
      }
    }
    while await entered.value == 0 { await Task.yield() }
    await pool.seek(60)
    do {
      _ = try await stale.value
      preconditionFailure("obsolete decode continued")
    } catch is CancellationError {}
    let again = try await pool.load(9) { all[0] }
    precondition(again.media == all[0].media)
    await pool.stop()
    do {
      _ = try await pool.load(8, make: build)
      preconditionFailure("read after stop")
    } catch is CancellationError {}
    print(
      "Swift playback: eight requests shared one real encode, initialization + media reassembled, seek cancelled obsolete work"
    )
  }
}
