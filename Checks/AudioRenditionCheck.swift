import Foundation

@main enum AudioRenditionCheck {
  static func main() async throws {
    let a = CommandLine.arguments
    precondition(
      AudioFilterChoice.valid("0") && AudioFilterChoice.valid("1") && AudioFilterChoice.valid("2"))
    precondition(AudioFilterChoice.valid("volume=0.5,dynaudnorm=f=200:g=5:r=0.75:p=0.6"))
    for invalid in [
      "amovie=other", "loudnorm=stats_file=2", "volume=+inf", "dynaudnorm=g=301:f=200",
      "volume=2;anull", "volume=volume=200", "loudnorm=TP=-1:TP=-4",
    ] { precondition(!AudioFilterChoice.valid(invalid)) }
    let volume = try JSONDecoder().decode(
      AudioMeasurements.self,
      from: Data(
        #"{"measured_i":-22.5,"measured_lra":5,"measured_tp":-4,"measured_threshold":-33,"target_offset":0.3,"target_i":-18,"target_tp":-1}"#
          .utf8))
    precondition(AudioFilterChoice.chain(main: "2", fallback: "0", gain: 100, volume: nil).isEmpty)
    let measured = AudioFilterChoice.chain(main: "2", fallback: "0", gain: 200, volume: volume)
    precondition(
      measured.contains("measured_I=-22.5") && measured.contains("TP=-4")
        && measured.contains("volume=volume=2"))
    let chain = AudioFilterChoice.chain(main: "2", fallback: "1", gain: 200, volume: nil)
    precondition(chain.hasPrefix("dynaudnorm=") && chain.hasSuffix(",volume=volume=2.0"))
    guard let span = ByteSpan(a[4]), let base = Int64(a[3]) else { fatalError() }
    let i = try Data(contentsOf: URL(fileURLWithPath: a[1]))
    let m = try Data(contentsOf: URL(fileURLWithPath: a[2]))
    let pool = DecoderSegments()
    let results = try await withThrowingTaskGroup(of: DecoderFragment.self) { group in
      for _ in 0..<5 {
        group.addTask {
          try await pool.load(2) {
            try await AudioSegment.convert(
              initial: i, media: m, offset: base, target: span, index: 2, filter: chain)
          }
        }
      }
      var out: [DecoderFragment] = []
      for try await v in group { out.append(v) }
      return out
    }
    precondition(
      results.count == 5
        && results.allSatisfy { $0.media == results[0].media && $0.encoding.codec == "alac" })
    try (results[0].initial + results[0].media).write(to: URL(fileURLWithPath: a[5]))
    await pool.stop()
  }
}
