import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum ResponseCookieOrigin {
  static func marked(_ cookies: [HTTPCookie], from url: URL) -> [HTTPCookie] {
    cookies.compactMap { cookie in
      guard var properties = cookie.properties else { return nil }
      properties[.originURL] = url
      return HTTPCookie(properties: properties)
    }
  }
  static func source(_ cookie: HTTPCookie, fallback: URL) -> URL {
    if let url = cookie.properties?[.originURL] as? URL { return url }
    if let raw = cookie.properties?[.originURL] as? String, let url = URL(string: raw) { return url }
    return fallback
  }
  static func received(_ response: HTTPURLResponse) -> [HTTPCookie] {
    guard let url = response.url else { return [] }
    return marked(HTTPCookie.cookies(withResponseHeaderFields: response.allHeaderFields as? [String: String] ?? [:], for: url), from: url)
  }
}
