import Foundation

#if canImport(Network)
  import Network
  import Darwin
#else
  import Glibc
#endif

struct APIProxy: Codable, Equatable {
  static let key = "network.httpProxy"
  var enabled = false, host = "", port = ""
  static func current(_ d: UserDefaults = .standard) -> Self {
    guard let bytes = d.data(forKey: key),
      let saved = try? JSONDecoder().decode(Self.self, from: bytes)
    else { return Self() }
    return saved
  }
  func validated() throws -> Self {
    let raw = host.trimmingCharacters(in: .whitespacesAndNewlines)
    var name = raw
    if name.hasPrefix("[") && name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
    let service = port.trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty {
      if name.contains(":") {
        var address = in6_addr()
        guard name.utf8.count < 64, !name.utf8.contains(0), inet_pton(AF_INET6, name, &address) == 1
        else { throw ServiceError("代理 IPv6 地址无效") }
      } else {
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard name == raw, name.utf8.count <= 253, !labels.isEmpty,
          labels.allSatisfy({
            (1...63).contains($0.utf8.count) && $0.first != "-" && $0.last != "-"
              && $0.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                  || $0 == 45
              }
          })
        else { throw ServiceError("请输入代理主机名或 IP 地址") }
        if name.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
          var address = in_addr()
          guard inet_pton(AF_INET, name, &address) == 1 else { throw ServiceError("代理 IPv4 地址无效") }
        }
      }
    }
    var number: UInt16?
    if !service.isEmpty {
      number = UInt16(service)
      guard service.utf8.allSatisfy({ (48...57).contains($0) }), number != nil, number != 0 else {
        throw ServiceError("代理端口应在 1 至 65535 之间")
      }
    }
    if enabled && (name.isEmpty || number == nil) { throw ServiceError("请填写代理主机和端口") }
    return Self(enabled: enabled, host: name.lowercased(), port: number.map(String.init) ?? "")
  }
  func save(_ d: UserDefaults = .standard) throws {
    let value = try validated()
    d.set(try JSONEncoder().encode(value), forKey: Self.key)
  }
  var endpoint: String { (host.contains(":") ? "[" + host + "]" : host) + ":" + port }
  #if canImport(Network)
    func apply(to config: URLSessionConfiguration) {
      guard enabled, let n = UInt16(port), n > 0, let port = NWEndpoint.Port(rawValue: n) else {
        return
      }
      let proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .init(host), port: port))
      config.proxyConfigurations = [proxy]
    }
  #endif
}
