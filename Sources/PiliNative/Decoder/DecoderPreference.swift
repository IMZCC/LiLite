import Foundation

enum NativeVideoRoute: String, CaseIterable {
  case direct = "系统直通"
  case copied = "系统解码并拷贝"
  case software = "软件解码"
  var converts: Bool { self != .direct }
}
enum DecoderPreference {
  static let enabledKey = "decoder.hardware", listKey = "decoder.choices"
  static let local = ["auto", "auto-safe", "auto-copy", "videotoolbox", "videotoolbox-copy", "no"]
  static let accepted = Set(
    local + [
      "d3d12va", "d3d12va-copy", "d3d11va", "d3d11va-copy", "dxva2", "dxva2-copy", "vaapi",
      "vaapi-copy",
      "nvdec", "nvdec-copy", "drm", "drm-copy", "vulkan", "vulkan-copy", "vdpau", "vdpau-copy",
      "mediacodec", "mediacodec-copy",
      "cuda", "cuda-copy", "crystalhd", "rkmpp", "amf", "amf-copy", "qsv", "qsv-copy",
    ])
  static func choices(_ raw: String) -> [String]? {
    let a = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard !a.isEmpty, a.count <= accepted.count, Set(a).count == a.count,
      a.allSatisfy(accepted.contains)
    else { return nil }
    return a
  }
  static func allowsDirect(enabled: Bool, settings: String) -> Bool {
    guard enabled else { return false }
    let ids = (choices(settings) ?? ["auto"]).filter(local.contains)
    for id in ids.isEmpty ? ["auto"] : ids {
      if id == "no" { return false }
      if ["auto", "auto-safe", "videotoolbox"].contains(id) { return true }
    }
    return false
  }
  static var allowsSystemFallback: Bool {
    allowsDirect(
      enabled: UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true,
      settings: UserDefaults.standard.string(forKey: listKey) ?? "auto")
  }
  static func routes(native: Bool, hardware: Bool, converts: Bool, enabled: Bool, settings: String)
    -> [NativeVideoRoute]
  {
    if !enabled { return converts ? [.software] : [] }
    let choices = (choices(settings) ?? ["auto"]).filter(local.contains)
    var result: [NativeVideoRoute] = []
    func add(_ r: NativeVideoRoute) { if !result.contains(r) { result.append(r) } }
    for id in choices.isEmpty ? ["auto"] : choices {
      switch id {
      case "no":
        if converts { add(.software) }
        return result
      case "videotoolbox-copy", "auto-copy": if hardware && converts { add(.copied) }
      default: if native && (hardware || !converts) { add(.direct) }
      }
    }
    if converts { add(.software) }
    // Native playback is useful for tracks without a separate software implementation, e.g. Dolby Vision.
    if result.isEmpty && native && allowsDirect(enabled: enabled, settings: settings) {
      add(.direct)
    }
    return result
  }
}
