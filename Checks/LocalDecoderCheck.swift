import Foundation

@main enum LocalDecoderCheck {
  static func main() async throws {
    let args = CommandLine.arguments
    func file(_ n: Int) -> URL { URL(fileURLWithPath: args[n]) }
    let video = try LocalFragmentIndex(url: file(1), audio: false)
    let scan = try LocalFragmentIndex(url: file(2), audio: false)
    let audio = try LocalFragmentIndex(url: file(3), audio: true)
    precondition(
      (video.codec.hasPrefix("av01") || video.codec.hasPrefix("hvc1.")
        || video.codec.hasPrefix("hev1.")) && audio.codec.hasPrefix("mp4a.40.")
        && video.width == 128
        && video.height == 72)
    precondition(
      video.fragments.count >= 3 && scan.fragments.count == video.fragments.count
        && audio.fragments.count >= 2)
    precondition(
      zip(video.fragments, scan.fragments).allSatisfy { abs($0.seconds - $1.seconds) < 0.001 })
    do {
      _ = try LocalFragmentIndex(url: file(4), audio: false)
      preconditionFailure("protected track accepted")
    } catch LocalIndexIssue.encrypted {}
    let k = video.fragments.count / 2
    let span = video.fragments[k].bytes
    let map = try video.file.data(video.initial.lower, Int(video.initial.count))
    let encoded = try await DecoderSegment.convert(
      initial: map, media: video.file.data(span.lower, Int(span.count)), source: span.lower,
      target: span.lower, index: k, route: .software)
    try (encoded.initial + encoded.media).write(to: file(5))
    // The original audio stream is served without mixing or transcoding.
    let a = audio.fragments[1].bytes
    let reassembled =
      try audio.file.data(audio.initial.lower, Int(audio.initial.count))
      + audio.file.data(a.lower, Int(a.count))
    try reassembled.write(to: file(6))
    print(
      "Offline: indexed \(video.fragments.count) video / \(audio.fragments.count) audio segments, middle seek, no-SIDX table reconstruction and protected-track rejection passed"
    )
  }
}
