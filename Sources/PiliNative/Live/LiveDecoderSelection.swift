import Foundation
import VideoToolbox

enum LiveDecoderSelection {
  static func family(_ f: LiveFormat) -> (CMVideoCodecType, Int32)? {
    switch f.codec.lowercased() {
    case "avc", "h264", "avc1": return (kCMVideoCodecType_H264, 1)
    case "hevc", "h265", "hvc1": return (kCMVideoCodecType_HEVC, 2)
    case "av1", "av01": return (kCMVideoCodecType_AV1, 3)
    case "vp9", "vp09": return (kCMVideoCodecType_VP9, 4)
    default: return nil
    }
  }
  static var settings: [String] {
    let d = UserDefaults.standard
    return [
      String(d.object(forKey: DecoderPreference.enabledKey) as? Bool ?? true),
      d.string(forKey: DecoderPreference.listKey) ?? "auto",
    ]
  }
  nonisolated static func routes(_ format: LiveFormat) async -> [NativeVideoRoute] {
    let c = family(format)
    let hardware = c.map { VTIsHardwareDecodeSupported($0.0) } ?? false
    let preferences = settings
    let choices = DecoderPreference.routes(
      native: hardware || c == nil, hardware: hardware, converts: c != nil,
      enabled: preferences[0] == "true", settings: preferences[1])
    if format.remux || (format.proto == "http_hls" && c != nil) { return choices }
    return choices.filter { $0 == .direct }
  }
}
struct LiveAccessRefused: LocalizedError {
  let code: Int
  var errorDescription: String? {
    switch code {
    case 429: return "直播服务器请求过于频繁，请稍后重试"
    case 412: return "直播服务器暂时拒绝了播放请求"
    default: return "当前账号没有这条直播线路的播放权限"
    }
  }
  static let statuses: Set<Int> = [401, 403, 412, 429]
}
