import Darwin
import Foundation
import Network

enum CastLAN {
  static func numeric(_ addr: UnsafePointer<sockaddr>) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    guard
      getnameinfo(
        addr, socklen_t(addr.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0,
        NI_NUMERICHOST) == 0
    else { return nil }
    return String(cString: buffer).lowercased()
  }
  static func interfaces() -> [(String, String)] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return [] }
    defer { freeifaddrs(list) }
    var p = list
    var items = [(String, String)]()
    while let a = p?.pointee {
      p = a.ifa_next
      let name = String(cString: a.ifa_name)
      guard name.hasPrefix("en"), a.ifa_flags & UInt32(IFF_UP) != 0, let addr = a.ifa_addr,
        [AF_INET, AF_INET6].contains(Int32(addr.pointee.sa_family)), let ip = numeric(addr)
      else { continue }
      items.append((name, ip))
    }
    return items
  }
  static func literal(_ host: String) -> String {
    host.contains(":") ? "[\(host.replacingOccurrences(of:"%",with:"%25"))]" : host
  }
  static func address(_ peer: URL) throws -> (local: String, remote: String) {
    guard CastAddress.safe(peer), let host = CastAddress.host(peer) else {
      throw CastProblem.address
    }
    var hint = addrinfo()
    hint.ai_flags = AI_NUMERICHOST
    hint.ai_socktype = SOCK_DGRAM
    var info: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, "9", &hint, &info) == 0, let info else { throw CastProblem.address }
    defer { freeaddrinfo(info) }
    let fd = socket(info.pointee.ai_family, SOCK_DGRAM, 0)
    guard fd >= 0 else { throw CastProblem.network }
    defer { Darwin.close(fd) }
    // UDP connect chooses a route without sending a datagram. Do not bind the media relay on
    // an unrelated interface (including a cellular link or a VPN).
    guard Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
      throw CastProblem.network
    }
    var storage = sockaddr_storage()
    var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let local = withUnsafeMutablePointer(to: &storage) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) { addr -> String? in
        guard getsockname(fd, addr, &len) == 0 else { return nil }
        return numeric(addr)
      }
    }
    guard let local, interfaces().contains(where: { equal($0.1, local) }) else {
      throw CastProblem.localPermission
    }
    return (local, host)
  }
  static func equal(_ a: String, _ b: String) -> Bool {
    let strip: (String) -> String = {
      $0.lowercased().replacingOccurrences(of: "%25", with: "%").components(separatedBy: "%")[0]
        .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
    let x = strip(a)
    let y = strip(b)
    if x == y || x == "::ffff:" + y || y == "::ffff:" + x { return true }
    var i = in6_addr()
    var j = in6_addr()
    guard inet_pton(AF_INET6, x, &i) == 1, inet_pton(AF_INET6, y, &j) == 1 else { return false }
    return withUnsafeBytes(of: i) { a in withUnsafeBytes(of: j) { a.elementsEqual($0) } }
  }
  static func peer(_ e: NWEndpoint, matches target: String) -> Bool {
    guard case .hostPort(let h, _) = e else { return false }
    switch h {
    case .ipv4(let v): return equal(v.debugDescription, target)
    case .ipv6(let v): return equal(v.debugDescription, target)
    default: return false
    }
  }
  static func location(_ raw: URL, peer: String? = nil) async throws -> URL {
    if CastAddress.safe(raw), let h = CastAddress.host(raw), peer.map({ equal(h, $0) }) ?? true {
      return raw
    }
    guard let h = CastAddress.host(raw), h.hasSuffix(".local"), h.utf8.count < 255,
      h.utf8.allSatisfy({
        $0 == 46 || $0 == 45 || (48...57).contains($0) || (97...122).contains($0)
      }), raw.scheme == "http", raw.user == nil, raw.password == nil, raw.fragment == nil
    else { throw CastProblem.address }
    return try await Task.detached {
      var opts = addrinfo()
      opts.ai_socktype = SOCK_STREAM
      opts.ai_flags = AI_ADDRCONFIG
      var list: UnsafeMutablePointer<addrinfo>?
      guard getaddrinfo(h, nil, &opts, &list) == 0 else { throw CastProblem.address }
      defer { freeaddrinfo(list) }
      var p = list
      while let record = p?.pointee {
        p = record.ai_next
        guard let addr = record.ai_addr, let numeric = numeric(addr),
          peer.map({ equal(numeric, $0) }) ?? true,
          var c = URLComponents(url: raw, resolvingAgainstBaseURL: false)
        else { continue }
        c.host = numeric.contains(":") ? "[\(numeric)]" : numeric
        if let url = c.url, CastAddress.safe(url) { return url }
      }
      throw CastProblem.address
    }.value
  }
}
