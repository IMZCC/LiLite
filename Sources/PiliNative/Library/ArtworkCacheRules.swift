import Foundation

enum ArtworkCacheRules {
  static func pixels(width: Double, height: Double, scale: Double) -> Int {
    guard width.isFinite, height.isFinite, scale.isFinite, width > 0, height > 0, scale > 0 else { return 384 }
    let required = max(width, height) * min(8, scale)
    return [96, 192, 384, 768, 1536, 2048].first { Double($0) >= required } ?? 2048
  }
  static func publicFile(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
      url.user == nil, url.password == nil, url.query == nil, url.port == nil || url.port == 443
    else { return false }
    return ["hdslb.com", "biliimg.com"].contains { host == $0 || host.hasSuffix("." + $0) }
  }
  static func admits(url: URL?, status: Int, mime: String?, cookie: String?, control: String?)
    -> Bool
  {
    guard let url, publicFile(url), status == 200, cookie == nil,
      mime?.lowercased().hasPrefix("image/") == true
    else { return false }
    let rules = (control ?? "").lowercased().split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    return !rules.contains { $0 == "no-store" || $0.hasPrefix("private") }
  }
}
