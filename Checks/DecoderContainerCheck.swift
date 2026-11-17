import Foundation

@main enum DecoderContainerCheck {
  static func main() throws {
    let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let clip = try DecoderFragment(bytes, index: 83)
    let codec = clip.encoding.codec ?? ""
    precondition(
      codec.hasPrefix(CommandLine.arguments[2]) && clip.encoding.width == 128
        && clip.encoding.height == 72)
    let stamp = clip.media.range(of: Data("mfhd".utf8))!.upperBound + 4
    precondition(clip.media[stamp..<stamp + 4].elementsEqual([0, 0, 0, 84]))
    precondition(clip.initial.count + clip.media.count == bytes.count)
    precondition(
      DecoderPreference.routes(
        native: true, hardware: true, converts: true, enabled: false, settings: "auto") == [
          .software
        ])
    precondition(
      DecoderPreference.routes(
        native: true, hardware: false, converts: true, enabled: true, settings: "auto") == [
          .software
        ])
    precondition(
      DecoderPreference.routes(
        native: true, hardware: true, converts: true, enabled: true,
        settings: "videotoolbox-copy,auto,no") == [.copied, .direct, .software])
    precondition(
      !DecoderPreference.allowsDirect(enabled: true, settings: "auto-copy,no")
        && DecoderPreference.allowsDirect(enabled: true, settings: "auto-copy,auto"))
    print(
      "HLS map: \(codec), \(clip.encoding.width)×\(clip.encoding.height), sequence number and engine order matched"
    )
  }
}
