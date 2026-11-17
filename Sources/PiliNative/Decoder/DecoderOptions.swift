import AVFoundation
import SwiftUI
import VideoToolbox

enum DecoderOptions {
  static func systemPlays(_ s: DashStream) -> Bool {
    let c = s.codecs
    guard !c.isEmpty,
      c.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
          || $0 == 46
      })
    else { return false }
    return c.lowercased().hasPrefix("avc1")
      || AVURLAsset.isPlayableExtendedMIMEType("video/mp4; codecs=\"" + c + "\"")
  }
  static func routes(_ s: DashStream) -> [NativeVideoRoute] {
    let family = s.codecs.lowercased()
    let codec: CMVideoCodecType?
    if family.hasPrefix("avc1") || family.hasPrefix("avc3") {
      codec = kCMVideoCodecType_H264
    } else if family.hasPrefix("hvc1") || family.hasPrefix("hev1") || family.hasPrefix("dvh1")
      || family.hasPrefix("dvhe")
    {
      codec = kCMVideoCodecType_HEVC
    } else if family.hasPrefix("av01") {
      codec = kCMVideoCodecType_AV1
    } else if family.hasPrefix("vp09") || family.hasPrefix("vp9") {
      codec = kCMVideoCodecType_VP9
    } else {
      codec = nil
    }
    let convertible = codec != nil && !family.hasPrefix("dv") && ![126, 129].contains(s.id)
    return DecoderPreference.routes(
      native: systemPlays(s), hardware: codec.map(VTIsHardwareDecodeSupported) ?? false,
      converts: convertible,
      enabled: UserDefaults.standard.object(forKey: DecoderPreference.enabledKey) as? Bool ?? true,
      settings: UserDefaults.standard.string(forKey: DecoderPreference.listKey) ?? "auto")
  }
}

struct DecoderSettings: View {
  @AppStorage(DecoderPreference.enabledKey) private var hardware = true
  @AppStorage(DecoderPreference.listKey) private var raw = "auto"
  private var ordered: [String] {
    (DecoderPreference.choices(raw) ?? ["auto"]).filter(DecoderPreference.local.contains)
  }
  private func write(_ value: [String]) {
    raw = value.isEmpty ? "auto" : value.joined(separator: ",")
  }
  private func label(_ s: String) -> String {
    [
      "auto": "自动", "auto-safe": "优先兼容", "auto-copy": "自动（拷贝）", "videotoolbox": "VideoToolbox 直通",
      "videotoolbox-copy": "VideoToolbox 拷贝", "no": "软件解码",
    ][s] ?? s
  }
  var body: some View {
    List {
      Toggle("使用硬件解码", isOn: $hardware).settingAnchor("DecoderSettings/使用硬件解码")
      if hardware {
        Section("优先顺序") {
          ForEach(ordered, id: \.self) { Text(label($0)) }
            .onDelete {
              var v = ordered
              v.remove(atOffsets: $0)
              write(v)
            }
            .onMove {
              var v = ordered
              v.move(fromOffsets: $0, toOffset: $1)
              write(v)
            }
          ForEach(DecoderPreference.local.filter { !ordered.contains($0) }, id: \.self) { id in
            Button {
              write(ordered + [id])
            } label: {
              Label(label(id), systemImage: "plus.circle")
            }
          }
        }.settingAnchor("DecoderSettings/优先顺序")
      }
      Button("恢复默认") {
        hardware = true
        raw = "auto"
      }
    }.navigationTitle("视频解码").toolbar { if hardware { EditButton() } }
  }
}
