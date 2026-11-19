import Foundation

struct GalleryPicture: Equatable, Hashable {
  let url: URL, motion: URL?
  init(_ url: URL, motion: URL? = nil) {
    self.url = url
    self.motion = motion
  }
  init?(_ data: [String: Any]) {
    guard let raw = data["url"] as? String ?? data["src"] as? String ?? data["img_src"] as? String,
      let cover = Self.source(raw)
    else { return nil }
    url = cover
    motion = (data["live_url"] as? String).flatMap(Self.source)
  }
  static func source(_ s: String) -> URL? {
    guard let u = httpsURL(s), u.user == nil, u.password == nil else { return nil }
    return u
  }
  /// Compiled once: every thumbnail asks for its display URL on each render.
  nonisolated(unsafe) private static let sizeSuffix = try? NSRegularExpression(
    pattern: #"(@(?:\d+[a-z]_?)*)(\.[a-z0-9]+)?$"#, options: .caseInsensitive)
  func display(quality: Int, minimum: Int = 1) -> URL {
    guard (1..<100).contains(quality), let host = url.host?.lowercased(),
      ["hdslb.com", "biliimg.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
      var c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.query == nil,
      c.fragment == nil
    else { return url }
    let q = min(100, max(quality, minimum))
    let path = c.percentEncodedPath
    if let match = Self.sizeSuffix?.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
      let r = Range(match.range, in: path),
      let params = Range(match.range(at: 1), in: path)
    {
      let suffix = Range(match.range(at: 2), in: path).map { String(path[$0]) } ?? ".webp"
      c.percentEncodedPath =
        String(path[..<r.lowerBound]) + String(path[params]) + "_\(q)q" + suffix
    } else {
      guard ["jpg", "jpeg", "png", "webp", "avif", "gif"].contains(url.pathExtension.lowercased())
      else { return url }
      c.percentEncodedPath = path + "@\(q)q.webp"
    }
    return c.url ?? url
  }
}
