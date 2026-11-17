import Foundation

/// WebDAV and SponsorBlock are user-selected endpoints, including ordinary LAN HTTP servers.
/// Origin equality keeps both scheme and effective port; certificate policy applies to HTTPS only.
enum SelfHostedServiceURL {
  static func parse(_ input: String) -> URL? {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.utf8.count <= 4096, !value.contains("\\"), value.rangeOfCharacter(from: .controlCharacters) == nil,
      var parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(),
      ["http", "https"].contains(scheme), let host = parts.host, !host.isEmpty,
      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
      parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
    parts.scheme = scheme
    return parts.url
  }
  static func port(_ url: URL) -> Int? {
    guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
    return url.port ?? (scheme == "http" ? 80 : 443)
  }
  private static func host(_ value: String?) -> String? {
    guard var host = value?.lowercased(), !host.isEmpty else { return nil }
    if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    return host
  }
  static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
    guard let scheme = first.scheme?.lowercased(), ["http", "https"].contains(scheme),
      scheme == second.scheme?.lowercased(), let name = host(first.host), name == host(second.host),
      port(first) == port(second), first.user == nil, first.password == nil, second.user == nil, second.password == nil else { return false }
    return true
  }
  static func matches(_ origin: URL, host: String, port: Int, scheme: String?) -> Bool {
    scheme?.lowercased() == origin.scheme?.lowercased() && Self.host(host) == Self.host(origin.host)
      && Self.port(origin) == port
  }
  static func allowsReadRedirect(method: String, from: URL, to: URL) -> Bool {
    ["GET", "HEAD"].contains(method.uppercased()) && sameOrigin(from, to)
  }
}
