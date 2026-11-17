import Foundation

struct LiveCDNOrigin: Equatable {
  let base: URL
  init?(_ input: String?) {
    guard let value = input?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
      value.utf8.count <= 500,
      !value.contains("\\"), !value.contains(where: { $0.isWhitespace || $0.isNewline })
    else { return nil }
    let raw = value.contains("://") ? value : "https://" + value
    guard var c = URLComponents(string: raw), c.scheme?.lowercased() == "https", let host = c.host,
      !host.isEmpty,
      c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
      c.port.map({ (1...65535).contains($0) }) ?? true
    else { return nil }
    let path = c.percentEncodedPath.removingPercentEncoding ?? ""
    guard !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
      !path.contains("\\")
    else { return nil }
    while c.percentEncodedPath.hasSuffix("/") { c.percentEncodedPath.removeLast() }
    c.scheme = "https"
    guard let url = c.url else { return nil }
    base = url
  }
  func stream(_ resource: String) -> URL? {
    guard resource.hasPrefix("/"), !resource.hasPrefix("//"), !resource.contains("\\"),
      !resource.contains(where: { $0.isWhitespace || $0.isNewline }),
      let u = URL(string: base.absoluteString + resource), u.host == base.host, u.port == base.port,
      u.user == nil, u.password == nil, u.fragment == nil
    else { return nil }
    return u
  }
}
extension LiveVariant {
  struct Route { let url: URL, line: Int }
  func routes(first: Int, custom: LiveCDNOrigin?) -> [Route] {
    var order = Array(endpoints.indices)
    if order.contains(first) {
      order.removeAll { $0 == first }
      order.insert(first, at: 0)
    }
    var seen = Set<URL>()
    var out = [Route]()
    for i in order {
      let e = endpoints[i]
      for url in [custom?.stream(e.resource), e.url].compactMap({ $0 })
      where seen.insert(url).inserted { out.append(.init(url: url, line: i)) }
    }
    return out
  }
}
