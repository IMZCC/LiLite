import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct CastAdvertisement: Sendable {
  let location: URL?, sender: String, udn: String, alive: Bool, age: Double
  static func parse(_ bytes: [UInt8], sender: String, fixture: Bool = false) -> Self? {
    guard bytes.count <= 8192, !bytes.contains(0), let msg = String(bytes: bytes, encoding: .utf8)
    else { return nil }
    let lines = msg.components(separatedBy: .newlines).filter { !$0.isEmpty }
    guard let start = lines.first else { return nil }
    let notify = start.uppercased() == "NOTIFY * HTTP/1.1"
    guard
      notify || start.uppercased().hasPrefix("HTTP/1.1 200 ")
        || start.uppercased().hasPrefix("HTTP/1.0 200 ")
    else { return nil }
    var fields = [String: String]()
    for l in lines.dropFirst() {
      guard let sep = l.firstIndex(of: ":") else { continue }
      let k = l[..<sep].trimmingCharacters(in: .whitespaces).lowercased()
      let v = l[l.index(after: sep)...].trimmingCharacters(in: .whitespaces)
      guard fields[k] == nil, fields.count < 50 else { return nil }
      fields[k] = v
    }
    let type = fields[notify ? "nt" : "st"]?.lowercased() ?? ""
    let usn = fields["usn"]?.components(separatedBy: "::").first?.lowercased() ?? ""
    let accepted =
      type.hasPrefix("urn:schemas-upnp-org:device:mediarenderer:")
      || type.hasPrefix("urn:schemas-upnp-org:service:avtransport:") || type == "upnp:rootdevice"
    guard accepted, usn.utf8.count < 192 else { return nil }
    if notify, fields["nts"]?.lowercased() == "ssdp:byebye", !usn.isEmpty {
      return Self(location: nil, sender: sender, udn: usn, alive: false, age: 0)
    }
    guard !notify || ["ssdp:alive", "ssdp:update"].contains(fields["nts"]?.lowercased() ?? ""),
      let raw = fields["location"], let u = URL(string: raw), let h = CastAddress.host(u),
      h == sender && CastAddress.safe(u, fixture: fixture)
        || h.hasSuffix(".local") && u.scheme == "http" && u.user == nil && u.password == nil
    else { return nil }
    let rawAge = fields["cache-control"]?.lowercased().split(separator: ",").compactMap {
      v -> Int? in
      let kv = v.trimmingCharacters(in: .whitespaces).split(separator: "=")
      return kv.count == 2 && kv[0].trimmingCharacters(in: .whitespaces) == "max-age"
        ? Int(kv[1].trimmingCharacters(in: .whitespaces)) : nil
    }.first
    return Self(
      location: u, sender: sender, udn: usn, alive: true,
      age: Double(max(1, min(120, rawAge ?? 120))))
  }
}
enum CastSSDP {
  private static let group = "239.255.255.250"
  private static func socketUDP() -> Int32 {
    #if canImport(Darwin)
      return socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    #else
      return socket(AF_INET, Int32(SOCK_DGRAM.rawValue), Int32(IPPROTO_UDP))
    #endif
  }
  private static func addr(_ ip: String, _ port: UInt16) -> sockaddr_in {
    var a = sockaddr_in()
    #if canImport(Darwin)
      a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    inet_pton(AF_INET, ip, &a.sin_addr)
    return a
  }
  private static func bind4(_ fd: Int32, _ ip: String, _ port: UInt16) -> Bool {
    var a = addr(ip, port)
    return withUnsafePointer(to: &a) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
  }
  #if canImport(Darwin)
    static func events() -> AsyncThrowingStream<CastAdvertisement, Error> {
      stream(
        port: 1900, fixture: false, lifetime: 20,
        interfaces: CastLAN.interfaces().map(\.1).filter { CastAddress.ipv4($0) != nil })
    }
  #else
    static func fixture(port: UInt16, seconds: Double) -> AsyncThrowingStream<
      CastAdvertisement, Error
    > { stream(port: port, fixture: true, lifetime: seconds, interfaces: ["127.0.0.1"], target: "127.0.0.1") }
  #endif
  #if canImport(Darwin)
    /// A directed UDP request needs local-network permission, but no multicast entitlement.
    static func unicast(_ ip: String) -> AsyncThrowingStream<CastAdvertisement, Error> {
      stream(port: 1900, fixture: false, lifetime: 5,
        interfaces: CastLAN.interfaces().map(\.1).filter { CastAddress.ipv4($0) != nil }, target: ip)
    }
  #endif
  private static func stream(port: UInt16, fixture: Bool, lifetime: Double, interfaces: [String], target: String? = nil)
    -> AsyncThrowingStream<CastAdvertisement, Error>
  {
    AsyncThrowingStream(bufferingPolicy: .bufferingNewest(128)) { sink in
      let job = Task.detached(priority: .utility) {
        do {
          guard !interfaces.isEmpty else { throw CastProblem.localPermission }
          let destination = target ?? (fixture ? "127.0.0.1" : group)
          let multicast = !fixture && target == nil
          var sockets = [Int32]()
          var clients = [Int32]()
          defer { for fd in sockets { _ = close(fd) } }
          for ip in interfaces.prefix(6) {
            let fd = socketUDP()
            guard fd >= 0 else { continue }
            guard bind4(fd, ip, 0) else {
              _ = close(fd)
              continue
            }
            if multicast {
              var i = in_addr()
              inet_pton(AF_INET, ip, &i)
              guard
                setsockopt(
                  fd, Int32(IPPROTO_IP), IP_MULTICAST_IF, &i, socklen_t(MemoryLayout<in_addr>.size))
                  == 0
              else {
                _ = close(fd)
                continue
              }
            }
            sockets.append(fd)
            clients.append(fd)
          }
          guard !clients.isEmpty else { throw CastProblem.localPermission }
          if multicast {
            let fd = socketUDP()
            if fd >= 0 {
              var yes: Int32 = 1
              _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, 4)
              #if canImport(Darwin)
                _ = setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, 4)
              #endif
              if bind4(fd, "0.0.0.0", 1900) {
                var joined = false
                for ip in interfaces {
                  var membership = ip_mreq()
                  inet_pton(AF_INET, group, &membership.imr_multiaddr)
                  inet_pton(AF_INET, ip, &membership.imr_interface)
                  if setsockopt(
                    fd, Int32(IPPROTO_IP), IP_ADD_MEMBERSHIP, &membership,
                    socklen_t(MemoryLayout<ip_mreq>.size)) == 0
                  {
                    joined = true
                  }
                }
                if joined { sockets.append(fd) } else { _ = close(fd) }
              } else {
                _ = close(fd)
              }
            }
          }
          var socketTarget = addr(destination, port)
          var fds = sockets.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
          let start = ProcessInfo.processInfo.systemUptime
          var next = start
          var count = 0
          var buf = [UInt8](repeating: 0, count: 8192)
          while ProcessInfo.processInfo.systemUptime < start + lifetime {
            try Task.checkCancellation()
            if ProcessInfo.processInfo.systemUptime >= next {
              let types =
                count == 0
                ? [
                  "urn:schemas-upnp-org:device:MediaRenderer:1",
                  "urn:schemas-upnp-org:service:AVTransport:1",
                ]
                : [
                  count % 2 == 0
                    ? "urn:schemas-upnp-org:device:MediaRenderer:1"
                    : "urn:schemas-upnp-org:service:AVTransport:1"
                ]
              var sent = false
              for fd in clients {
                for type in types {
                  let bytes = Array(
                    "M-SEARCH * HTTP/1.1\r\nHOST: \(destination):\(port)\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(type)\r\n\r\n"
                      .utf8)
                  let n = bytes.withUnsafeBytes { b in
                    withUnsafePointer(to: &socketTarget) { p in
                      p.withMemoryRebound(to: sockaddr.self, capacity: 1) { a in
                        sendto(
                          fd, b.baseAddress, b.count, 0, a,
                          socklen_t(MemoryLayout<sockaddr_in>.size))
                      }
                    }
                  }
                  if n == bytes.count { sent = true }
                }
              }
              if !sent { throw CastProblem.localPermission }
              count += 1
              next = ProcessInfo.processInfo.systemUptime + 2
            }
            let ready = fds.withUnsafeMutableBufferPointer {
              poll($0.baseAddress, nfds_t($0.count), 160)
            }
            if ready < 0 && errno != EINTR { throw CastProblem.network }
            if ready <= 0 { continue }
            for p in fds where p.revents & Int16(POLLIN) != 0 {
              var from = sockaddr_in()
              var length = socklen_t(MemoryLayout<sockaddr_in>.size)
              let n = buf.withUnsafeMutableBytes { b in
                withUnsafeMutablePointer(to: &from) { s in
                  s.withMemoryRebound(to: sockaddr.self, capacity: 1) { a in
                    recvfrom(p.fd, b.baseAddress, b.count, 0, a, &length)
                  }
                }
              }
              guard n > 0 else { continue }
              var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
              guard inet_ntop(AF_INET, &from.sin_addr, &ip, socklen_t(ip.count)) != nil else {
                continue
              }
              let sender = String(cString: ip)
              if (target == nil || target == sender), let e = CastAdvertisement.parse(
                Array(buf.prefix(n)), sender: sender, fixture: fixture)
              {
                sink.yield(e)
              }
            }
          }
          sink.finish()
        } catch { sink.finish(throwing: error) }
      }
      sink.onTermination = { _ in job.cancel() }
    }
  }
}
