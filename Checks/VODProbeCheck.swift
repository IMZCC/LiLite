import Foundation

@main enum VODProbeCheck {
  static func main() async throws {
    let root = URL(string: CommandLine.arguments[1])!
    let client = RangeTransport()
    defer { client.close() }
    for (path, count) in [("whole", 256 * 1024), ("short", 37)] {
      let sample = try await VODSpeedProbe.sample(
        root.appendingPathComponent(path), reference: root, via: client)
      precondition(sample.bytes == count && sample.bytesPerSecond > 0)
    }
    for (path, code) in [("forbidden", 403), ("ignores", 200), ("truncated", 0)] {
      do {
        _ = try await VODSpeedProbe.sample(
          root.appendingPathComponent(path), reference: root, via: client)
        preconditionFailure("accepted invalid response: " + path)
      } catch let e as RangeHTTPStatus { precondition(e.code == code) } catch {
        precondition(code == 0)
      }
    }
    let started = ProcessInfo.processInfo.systemUptime
    let pending = Task {
      try await VODSpeedProbe.sample(
        root.appendingPathComponent("slow"), reference: root, via: client)
    }
    try await Task.sleep(for: .milliseconds(100))
    pending.cancel()
    do {
      _ = try await pending.value
      preconditionFailure("cancelled probe succeeded")
    } catch {}
    precondition(ProcessInfo.processInfo.systemUptime - started < 4)
    let cast = CastMediaSource(
      urls: ["castA", "castB", "castC"].map { root.appendingPathComponent($0) }, reference: root)
    let probe = try await cast.range(0, 0)
    precondition(probe.total == 64)
    let middle = try await cast.range(4, 7, total: probe.total)
    let next = try await cast.range(8, 11, total: probe.total)
    precondition(middle.data == Data([4, 5, 6, 7]) && next.data == Data([8, 9, 10, 11]))
    await cast.close()
    let denied = CastMediaSource(
      urls: ["castDenied", "castMustNotFetch"].map { root.appendingPathComponent($0) },
      reference: root)
    do {
      _ = try await denied.range(0, 3)
      preconditionFailure("forbidden source used a mirror")
    } catch let e as RangeHTTPStatus { precondition(e.code == 403) }
    await denied.close()
    print(
      "Cast: seek, failed primary, different-length and sticky mirrors, 403 stops before any mirror passed"
    )
    print(
      "VOD samples: full, short EOF, denied, ignored Range, truncated body, cancellation passed")
  }
}
