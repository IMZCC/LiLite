import Foundation

/// Provider IDs are the strings written by PiliPlus backups. Only ordinary UPOS origins can
/// substitute for one another; provider-specific authorizations remain on their issued origins.
enum VODLine: String, CaseIterable, Identifiable {
  case baseUrl, backupUrl, ali, alib, alio1, cos, cosb, coso1, hw, hwb, hwo1
  case hw_08c, hw_08h, hw_08ct, tf_hw, tf_tx, akamai, aliov, cosov, hwov, hk_bcache
  var id: Self { self }
  static let key = "vod.line", audioKey = "vod.independentAudio", testKey = "vod.speedTest"
  var host: String? {
    switch self {
    case .baseUrl, .backupUrl: return nil
    case .tf_hw: return "upos-tf-all-hw.bilivideo.com"
    case .tf_tx: return "upos-tf-all-tx.bilivideo.com"
    case .akamai: return "upos-hz-mirrorakam.akamaized.net"
    case .hk_bcache: return "cn-hk-eq-bcache-01.bilivideo.com"
    case .hw_08c, .hw_08h, .hw_08ct:
      return "upos-sz-mirror" + String(rawValue.dropFirst(3)) + ".bilivideo.com"
    default: return "upos-sz-mirror" + rawValue + ".bilivideo.com"
    }
  }
  var label: String {
    switch self {
    case .baseUrl: return "主线路"
    case .backupUrl: return "备用线路"
    case .akamai: return "Akamai · 海外"
    case .hk_bcache: return "哔哩哔哩 · 香港"
    case .ali, .alib, .alio1, .aliov: return "阿里云 · " + rawValue
    case .cos, .cosb, .coso1, .cosov, .tf_tx: return "腾讯云 · " + rawValue
    default: return "华为云 · " + rawValue
    }
  }
  private var ordinary: Bool {
    switch self {
    case .baseUrl, .backupUrl, .tf_hw, .tf_tx, .akamai, .hk_bcache: return false
    default: return true
    }
  }
  private static let mirrors = Set(allCases.filter(\.ordinary).compactMap(\.host))
  private static func transferable(_ u: URL) -> Bool {
    guard let c = URLComponents(url: u, resolvingAgainstBaseURL: false),
      let host = c.host?.lowercased(), mirrors.contains(host), c.port == nil,
      c.percentEncodedPath.hasPrefix("/upgcxcode/")
    else { return false }
    return !(c.queryItems ?? []).contains {
      ["hdnts", "hdnea", "xy_usource", "drm", "token"].contains($0.name.lowercased())
        || ($0.name.lowercased() == "os" && $0.value?.lowercased() == "mcdn")
    }
  }
  static func originals(_ input: [URL]) -> [URL] {
    var seen = Set<String>()
    return input.filter {
      $0.scheme?.lowercased() == "https" && $0.host != nil && $0.user == nil && $0.password == nil
        && $0.fragment == nil && seen.insert($0.absoluteString).inserted
    }
  }
  /// Nil means the sample has no usable route for this provider; never report another line's speed.
  func candidate(_ input: [URL]) -> URL? {
    let urls = Self.originals(input)
    switch self {
    case .baseUrl: return urls.first
    case .backupUrl:
      return urls.first(where: Self.transferable) ?? urls.dropFirst().first ?? urls.first
    default:
      if let match = urls.first(where: { $0.host?.lowercased() == host }) { return match }
      guard ordinary, let source = urls.first(where: Self.transferable),
        var c = URLComponents(url: source, resolvingAgainstBaseURL: false)
      else { return nil }
      c.host = host
      return c.url
    }
  }
  func routes(_ urls: [URL], audio: Bool, independent: Bool) -> [URL] {
    let line: Self = audio && independent && self != .baseUrl ? .backupUrl : self
    return Self.originals([line.candidate(urls)].compactMap { $0 } + urls)
  }
  static func current(_ urls: [URL], audio: Bool = false, defaults: UserDefaults = .standard)
    -> [URL]
  {
    let line = defaults.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .backupUrl
    return line.routes(urls, audio: audio, independent: defaults.bool(forKey: audioKey))
  }
}
