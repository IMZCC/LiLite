import Foundation

enum DecoderProblem: Error { case unsupported, size }
@main enum LiveTimingCheck {
  static func main() async throws {
    let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let local = folder.appendingPathComponent("index.m3u8")
    let text = try String(contentsOf: local, encoding: .utf8)
    let (rows, _) = LiveTimingSource.parse(text)!
    precondition(rows.count >= 5)
    let source = LiveTimingSource(folder: folder)
    let url = URL(string: "http://127.0.0.1:1/test/index.m3u8")!
    source.open(url)
    defer { source.stop() }
    let offset = rows[0].date - 20.0
    source.locate(itemTime: 22.5, date: Date(timeIntervalSince1970: offset + 22.5))
    precondition(PictureTimingRegistry.shared.source(url) === source)
    var end: Double?
    var delta = 0.0
    var origin = 0.0
    var starts = [Int: Double]()
    for slot in rows {
      let t = slot.date - offset
      precondition(source.clockIndex(at: t + slot.duration / 2) == slot.n)
      guard let part = try await source.clockPart(slot.n), let video = part.pcm.videoStart else {
        fatalError("missing multiplexed clock \(slot.n)")
      }
      let lag = Double(part.pcm.startSample) / Double(part.pcm.rate) - video
      if slot.n == rows[0].n {
        delta = lag
        let negative = CommandLine.arguments.count > 2
        precondition(
          negative ? (-0.4 ... -0.12).contains(lag) : (0.12...0.36).contains(lag),
          "unexpected offset \(lag)")
        origin = t - min(video, Double(part.pcm.startSample) / Double(part.pcm.rate))
      }
      precondition(
        abs(part.start - (origin + Double(part.pcm.startSample) / Double(part.pcm.rate))) < 0.00001)
      starts[slot.n] = part.start
      if let end {
        precondition(
          abs(end - part.start) < 0.00005, "sequence clock discontinuity \(end) -> \(part.start)")
      }
      end = part.start + part.pcm.duration
    }
    // Move the AVPlayer's live epoch without changing source PTS. New date mapping is taken
    // from the player; old media sequence zero is not used as a clock.
    let selected = rows[3]
    source.locate(itemTime: 803.5, date: Date(timeIntervalSince1970: selected.date + 0.5))
    precondition(source.clockIndex(at: 803.5) == selected.n)
    let next = try await source.clockPart(selected.n)!
    precondition(abs(next.start - (starts[selected.n]! + 803 - (selected.date - offset))) < 0.00001)
    source.stop()
    precondition(source.clockIndex(at: 803.5) == nil)
    do {
      _ = try await source.clockPart(selected.n)
      fatalError("retired source")
    } catch is CancellationError {}
    print(
      String(
        format:
          "Local rolling live: %d multiplexed H.264/AAC slots, retained %.1f ms source audio offset, rebased item time 803.5 s, closure cancelled access",
        rows.count, delta * 1000))
  }
}
