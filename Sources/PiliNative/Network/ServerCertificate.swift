import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Structural checks only. The TLS stack verifies signatures, key usage and the complete chain.
struct PrivateServiceOrigin: Hashable {
  enum Service: String { case dav, sponsor }
  let service: Service, host: String, port: Int
  init?(_ service: Service, _ url: URL) {
    guard url.scheme?.lowercased() == "https", var h = url.host?.lowercased(), !h.isEmpty,
      url.user == nil && url.password == nil
    else { return nil }
    if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
    if h.hasSuffix(".") { h.removeLast() }
    let p = url.port ?? 443
    guard (1...65535).contains(p),
      Self.ip(h) != nil
        || (!h.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) && h.utf8.count <= 253
          && h.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-"
              && $0.utf8.allSatisfy {
                (97...122).contains($0) || (48...57).contains($0) || $0 == 45
              }
          })
    else { return nil }
    let protected = [
      "bilibili.com", "bilibili.tv", "bilibili.cn", "biliapi.net", "biliapi.com", "b23.tv",
      "hdslb.com", "bilivideo.com", "bilivideo.cn", "biliimg.com", "acgvideo.com", "biligame.com",
      "biligame.net", "bsbsb.top", "sponsor.ajay.app",
    ]
    guard !protected.contains(where: { h == $0 || h.hasSuffix("." + $0) }) else { return nil }
    self.service = service
    host = h
    port = p
  }
  static func ip(_ host: String) -> Data? {
    var a = in_addr()
    var b = in6_addr()
    if inet_pton(AF_INET, host, &a) == 1 { return withUnsafeBytes(of: &a) { Data($0) } }
    if inet_pton(AF_INET6, host, &b) == 1 { return withUnsafeBytes(of: &b) { Data($0) } }
    return nil
  }
  var display: String {
    (host.contains(":") ? "[\(host)]" : host) + (port == 443 ? "" : ":\(port)")
  }
  var key: String { "\(service.rawValue)|\(host)|\(port)" }
  func matches(_ host: String, _ port: Int) -> Bool {
    var h = host.lowercased()
    if h.first == "[" && h.last == "]" { h = String(h.dropFirst().dropLast()) }
    if h.hasSuffix(".") { h.removeLast() }
    let a = Self.ip(h)
    let b = Self.ip(self.host)
    return port == self.port && ((a != nil && a == b) || h == self.host)
  }
}
struct PrivateCertificate {
  let der: Data, before: Date, after: Date, authority: Bool
  let dns: [String], ips: [Data]
  enum Parse: Error { case invalid }
  private struct Node { let tag: UInt8, bytes: Data }
  private static func nodes(_ bytes: Data) throws -> [Node] {
    let a = Array(bytes)
    var i = 0
    var result = [Node]()
    while i < a.count {
      guard result.count < 4096, i + 2 <= a.count else { throw Parse.invalid }
      let tag = a[i]
      let length = Int(a[i + 1])
      i += 2
      var n = length
      if length >= 128 {
        let count = length - 128
        guard (1...4).contains(count), i + count <= a.count, a[i] != 0 else { throw Parse.invalid }
        n = 0
        for _ in 0..<count {
          n = n * 256 + Int(a[i])
          i += 1
        }
        guard n >= 128 else { throw Parse.invalid }
      }
      guard n <= a.count - i else { throw Parse.invalid }
      result.append(.init(tag: tag, bytes: Data(a[i..<i + n])))
      i += n
    }
    return result
  }
  private static func time(_ node: Node) throws -> Date {
    guard let s = String(data: node.bytes, encoding: .ascii), s.last == "Z",
      [0x17, 0x18].contains(node.tag)
    else { throw Parse.invalid }
    let chars = Array(s.dropLast().utf8)
    let yearLen = node.tag == 0x17 ? 2 : 4
    guard chars.count == yearLen + 10, chars.allSatisfy({ (48...57).contains($0) }) else {
      throw Parse.invalid
    }
    func num(_ start: Int, _ len: Int) -> Int {
      chars[start..<start + len].reduce(0) { $0 * 10 + Int($1 - 48) }
    }
    var y = num(0, yearLen)
    if yearLen == 2 { y += y >= 50 ? 1900 : 2000 }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = DateComponents(
      year: y, month: num(yearLen, 2), day: num(yearLen + 2, 2), hour: num(yearLen + 4, 2),
      minute: num(yearLen + 6, 2), second: num(yearLen + 8, 2))
    guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else {
      throw Parse.invalid
    }
    return date
  }
  init(_ data: Data) throws {
    guard !data.isEmpty, data.count <= 128 * 1024 else { throw Parse.invalid }
    let der: Data
    if data.first == 0x30 {
      der = data
    } else {
      guard let p = String(data: data, encoding: .utf8) else { throw Parse.invalid }
      let lines = p.split(whereSeparator: \.isNewline).map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      }.filter { !$0.isEmpty }
      guard lines.count >= 3, lines.first == "-----BEGIN CERTIFICATE-----",
        lines.last == "-----END CERTIFICATE-----",
        let bytes = Data(base64Encoded: lines.dropFirst().dropLast().joined())
      else { throw Parse.invalid }
      der = bytes
    }
    let root = try Self.nodes(der)
    guard root.count == 1, root[0].tag == 0x30 else { throw Parse.invalid }
    let cert = try Self.nodes(root[0].bytes)
    guard cert.count == 3, cert[0].tag == 0x30, cert[1].tag == 0x30, cert[2].tag == 0x03 else {
      throw Parse.invalid
    }
    let tbs = try Self.nodes(cert[0].bytes)
    let start = tbs.first?.tag == 0xa0 ? 1 : 0
    guard tbs.count >= start + 6, tbs[start].tag == 2, tbs[start + 3].tag == 0x30 else {
      throw Parse.invalid
    }
    let dates = try Self.nodes(tbs[start + 3].bytes)
    guard dates.count == 2 else { throw Parse.invalid }
    before = try Self.time(dates[0])
    after = try Self.time(dates[1])
    self.der = der
    var ca = false
    var names: [String] = []
    var addresses: [Data] = []
    var seen = Set<Data>()
    if let box = tbs.dropFirst(start + 6).first(where: { $0.tag == 0xa3 }) {
      let seq = try Self.nodes(box.bytes)
      guard seq.count == 1, seq[0].tag == 0x30 else { throw Parse.invalid }
      for e in try Self.nodes(seq[0].bytes) {
        guard e.tag == 0x30 else { throw Parse.invalid }
        let value = try Self.nodes(e.bytes)
        guard (2...3).contains(value.count), value[0].tag == 6, let last = value.last,
          last.tag == 4,
          seen.insert(value[0].bytes).inserted
        else { throw Parse.invalid }
        if value[0].bytes == Data([85, 29, 19]) || value[0].bytes == Data([85, 29, 17]) {
          let wrapped = try Self.nodes(last.bytes)
          guard wrapped.count == 1, wrapped[0].tag == 0x30 else { throw Parse.invalid }
          let entries = try Self.nodes(wrapped[0].bytes)
          if value[0].bytes == Data([85, 29, 19]) {
            ca = entries.first?.tag == 1 && entries.first?.bytes == Data([255])
          } else {
            for n in entries {
              if n.tag == 0x82, let name = String(data: n.bytes, encoding: .ascii) {
                names.append(name.lowercased())
              } else if n.tag == 0x87 && [4, 16].contains(n.bytes.count) {
                addresses.append(n.bytes)
              }
            }
          }
        }
      }
    }
    authority = ca
    dns = names
    ips = addresses
  }
  func valid(at now: Date = .now) -> Bool { before <= now && now <= after }
  func matches(_ host: String) -> Bool {
    if let ip = PrivateServiceOrigin.ip(host) { return ips.contains(ip) }
    let h = host.lowercased()
    return dns.contains { name in
      if name == h { return true }
      guard name.hasPrefix("*."), !name.dropFirst(2).contains("*") else { return false }
      let labels = h.split(separator: ".", omittingEmptySubsequences: false)
      let pattern = name.split(separator: ".", omittingEmptySubsequences: false)
      return labels.count == pattern.count && pattern.count >= 3 && !labels[0].isEmpty
        && labels.dropFirst().elementsEqual(pattern.dropFirst())
    }
  }
}
