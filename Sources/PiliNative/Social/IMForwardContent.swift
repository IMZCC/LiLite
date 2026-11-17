import Foundation

struct IMForwardPhoto {
  let url: URL, width: Int, height: Int, type: String, size: Double?
  init?(_ content: [String: Any]) {
    guard let raw = content["url"] as? String, let u = URL(string: raw),
      u.scheme?.lowercased() == "https", u.user == nil, u.password == nil, (u.port ?? 443) == 443,
      let host = u.host?.lowercased(),
      ["hdslb.com", "biliimg.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
      let x = content["width"] as? Int, let y = content["height"] as? Int, (1...20000).contains(x),
      (1...20000).contains(y)
    else { return nil }
    let ext = ((content["imageType"] as? String) ?? u.pathExtension).lowercased()
    guard ["jpg", "jpeg", "png", "gif", "webp"].contains(ext) else { return nil }
    url = u
    width = x
    height = y
    type = ext
    size = (content["size"] as? NSNumber)?.doubleValue.flatMapFinite
  }
  var fields: [String: Any] {
    var v: [String: Any] = [
      "url": url.absoluteString, "width": width, "height": height, "imageType": type, "original": 1,
    ]
    if let size { v["size"] = size }
    return v
  }
}
extension Double { fileprivate var flatMapFinite: Double? { isFinite && self >= 0 ? self : nil } }
enum IMForwardContent {
  case text(String)
  case photo(IMForwardPhoto)
  case card(IMShareCard)
  static func read(type: Int?, fields: [String: Any]) -> Self? {
    if type == 1, let s = fields["content"] as? String,
      !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, s.utf8.count <= 64 * 1024
    {
      return .text(s)
    }
    if type == 2, let p = IMForwardPhoto(fields) { return .photo(p) }
    return IMShareCard.incoming(type, fields).map(Self.card)
  }
}
