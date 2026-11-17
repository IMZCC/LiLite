import Foundation

@main enum LegacyFLVWindowCheck {
  static func main() async throws {
    let args = CommandLine.arguments, source = try LocalMediaFile(URL(fileURLWithPath: args[1]))
    let folder = URL(fileURLWithPath: args[2], isDirectory: true), sparse = args.count > 3
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let counter = Counter()
    let (index, prefix) = try await LegacyFLVIndex.open(total: source.length, hint: nil) { at, n in
      counter.add(n); return try source.data(at, n)
    }
    precondition(index.parts.count >= 2 && index.prefixLength == Int64(prefix.count))
    let wanted = sparse ? [0, index.parts.count - 2] : Array(index.parts.indices)
    var read = counter.total
    for n in wanted {
      let part = index.parts[n], input = folder.appendingPathComponent("\(n).flv"), output = folder.appendingPathComponent("\(n).mp4")
      let payload = try source.data(part.offset, Int(part.end - part.offset)); read += payload.count
      try (prefix.prefix(Int(index.prefixLength)) + payload).write(to: input)
      try await LegacyMovieRemux.convert(input, to: output, beginning: part.start)
      let (v, a) = try LocalMovieFragments.open(LocalMediaFile(output))
      for (lane, track) in [("v", Optional(v)), ("a", a)] {
        guard let track else { continue }
        let directory = folder.appendingPathComponent(lane, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let initial = try track.file.data(track.initial.lower, Int(track.initial.count))
        var media = Data()
        for fragment in track.fragments { media.append(try track.file.data(fragment.bytes.lower, Int(fragment.bytes.count))) }
        let shifted = try LegacyFragmentTime.shifted(media, initial: initial, seconds: part.start)
        try initial.write(to: directory.appendingPathComponent("init-\(n).mp4"))
        try shifted.write(to: directory.appendingPathComponent("\(n).m4s"))
        try index.playlist().write(to: directory.appendingPathComponent("index.m3u8"))
      }
    }
    if sparse { precondition(Int64(read) < source.length / 3) }
    try JSONSerialization.data(withJSONObject: ["parts": index.parts.count, "read": read, "total": source.length,
      "starts": wanted.map { index.parts[$0].start }, "chosen": wanted]).write(to: folder.appendingPathComponent("probe.json"))
    print("Indexed FLV: \(wanted.count)/\(index.parts.count) GOPs prepared with \(read)/\(source.length) bytes, remote seek metadata and fragment time offsets passed")
  }
}
private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func add(_ n: Int) { lock.withLock { value += n } }
  var total: Int { lock.withLock { value } }
}
