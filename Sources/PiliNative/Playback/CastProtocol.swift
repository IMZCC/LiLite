import Foundation

#if canImport(FoundationXML)
  import FoundationXML
#endif
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

enum CastProblem: LocalizedError, Equatable {
  case address, description, unsupported, network, reply, denied, stale, localPermission, foreign,
    timeout
  case fault(Int, String)
  var errorDescription: String? {
    switch self {
    case .address: "请输入同一局域网设备的描述地址"
    case .description: "设备没有提供可用的投屏服务"
    case .unsupported: "设备不支持这个操作"
    case .network: "无法连接投屏设备"
    case .reply: "设备没有返回有效回执"
    case .denied: "服务未授权此内容投屏"
    case .stale: "播放账号或视频已变更"
    case .localPermission: "无法访问局域网，请在系统设置中允许本地网络，或手动连接设备"
    case .foreign: "设备已在播放其他内容"
    case .timeout: "投屏设备未及时响应"
    case .fault(let n, let s): s.isEmpty ? "设备返回错误 \(n)" : "\(s)（\(n)）"
    }
  }
}
enum CastAddress {
  static func host(_ url: URL) -> String? {
    url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
  }
  static func ipv4(_ s: String) -> [UInt8]? {
    let p = s.split(separator: ".", omittingEmptySubsequences: false)
    guard p.count == 4,
      p.allSatisfy({
        $0.utf8.allSatisfy { (48...57).contains($0) } && !$0.isEmpty
          && ($0.count == 1 || $0.first != "0")
      }), p.allSatisfy({ UInt8($0) != nil })
    else { return nil }
    return p.compactMap { UInt8($0) }
  }
  static func safe(_ u: URL, fixture: Bool = false) -> Bool {
    guard ["http", "https"].contains(u.scheme?.lowercased()), let h = host(u), u.user == nil,
      u.password == nil, u.fragment == nil, u.absoluteString.utf8.count <= 2048,
      (1...65535).contains(u.port ?? 80)
    else { return false }
    if let v = ipv4(h) {
      if fixture { return v[0] == 127 }
      return v[0] == 10 || v[0] == 192 && v[1] == 168 || v[0] == 172 && (16...31).contains(v[1])
        || v[0] == 169 && v[1] == 254 || fixture && v[0] == 127
    }
    var a = in6_addr()
    guard inet_pton(AF_INET6, h.components(separatedBy: "%")[0], &a) == 1 else { return false }
    let bytes = withUnsafeBytes(of: a) { Array($0) }
    if fixture { return bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1 }
    return bytes[0] & 0xfe == 0xfc || bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
      || fixture && bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
  }
  static func child(_ text: String, from base: URL, fixture: Bool, alias: String? = nil) -> URL? {
    guard var u = URL(string: text, relativeTo: base)?.absoluteURL, u.scheme == base.scheme else {
      return nil
    }
    // An mDNS name was resolved to this numeric host before fetching the description.
    // Apply that same mapping to absolute service URLs without querying a second hostname.
    if let alias, alias.hasSuffix(".local"), host(u) == alias,
      var c = URLComponents(url: u, resolvingAgainstBaseURL: false)
    {
      c.host = URLComponents(url: base, resolvingAgainstBaseURL: false)?.host
      guard let resolved = c.url else { return nil }
      u = resolved
    }
    guard safe(u, fixture: fixture), host(u) == host(base) else { return nil }
    return u
  }
}
enum CastKind: String {
  case transport = "AVTransport"
  case render = "RenderingControl"
  func version(_ urn: String) -> Int? {
    let pre = "urn:schemas-upnp-org:service:" + rawValue + ":"
    guard urn.hasPrefix(pre), let i = Int(urn.dropFirst(pre.count)), (1...9).contains(i),
      urn == pre + String(i)
    else { return nil }
    return i
  }
}
struct CastService: Equatable { let urn: String, control: URL, scpd: URL? }
struct CastDevice: Identifiable, Equatable {
  let name: String, id: String, location: URL, transport: CastService, render: CastService?
  var endpoint: URL { transport.control }
}
enum CastAction: String, CaseIterable {
  case set = "SetAVTransportURI"
  case play = "Play"
  case pause = "Pause"
  case stop = "Stop"
  case seek = "Seek"
  case position = "GetPositionInfo"
  case state = "GetTransportInfo"
  case actions = "GetCurrentTransportActions"
  case media = "GetMediaInfo"
  case volume = "GetVolume"
  case setVolume = "SetVolume"
  case mute = "GetMute"
  case setMute = "SetMute"
  var kind: CastKind {
    switch self {
    case .volume, .setVolume, .mute, .setMute: .render
    default: .transport
    }
  }
}
struct CastVolumeRange: Equatable {
  let min: Int, max: Int, step: Int
  static let standard = Self(min: 0, max: 100, step: 1)
  func native(_ percent: Double) -> Int {
    guard percent.isFinite else { return min }
    let p = Swift.max(0, Swift.min(1, percent / 100))
    return Swift.min(max, min + Int((Double(max - min) * p / Double(step)).rounded()) * step)
  }
  func percent(_ native: Int) -> Double {
    100 * Double(Swift.min(max, Swift.max(min, native)) - min) / Double(max - min)
  }
}
struct CastCapabilities {
  var actions: Set<CastAction>?, volumeRange = CastVolumeRange.standard
  func supports(_ a: CastAction) -> Bool { actions?.contains(a) ?? true }
}
// A small bounded XML tree for the description, SCPD and SOAP reply; namespace prefixes may vary.
private final class CastXMLNode {
  let name: String, ns: String
  var text = "", children: [CastXMLNode] = []
  init(_ n: String, _ ns: String) {
    name = n
    self.ns = ns
  }
  func one(_ name: String) -> CastXMLNode? {
    children.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
  }
  func field(_ name: String) -> String? {
    one(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  func descendants(_ name: String) -> [CastXMLNode] {
    children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
  }
}
private final class CastXML: NSObject, XMLParserDelegate {
  private var stack = [CastXMLNode](), count = 0
  private var root: CastXMLNode?
  static func parse(_ d: Data) throws -> CastXMLNode {
    guard !d.isEmpty, d.count <= 512 * 1024, let body = String(data: d, encoding: .utf8),
      !body.localizedCaseInsensitiveContains("<!DOCTYPE"),
      !body.localizedCaseInsensitiveContains("<!ENTITY")
    else { throw CastProblem.reply }
    let x = CastXML()
    let p = XMLParser(data: d)
    p.shouldProcessNamespaces = true
    p.shouldResolveExternalEntities = false
    p.delegate = x
    guard p.parse(), x.stack.isEmpty, let root = x.root else { throw CastProblem.reply }
    return root
  }
  func parser(
    _ parser: XMLParser, didStartElement n: String, namespaceURI: String?, qualifiedName: String?,
    attributes: [String: String] = [:]
  ) {
    count += 1
    guard count <= 12000, stack.count < 32 else {
      parser.abortParsing()
      return
    }
    let v = CastXMLNode(n, namespaceURI ?? "")
    if let a = stack.last { a.children.append(v) } else { root = v }
    stack.append(v)
  }
  func parser(_ p: XMLParser, foundCharacters s: String) {
    guard let v = stack.last, v.text.utf8.count + s.utf8.count < 65536 else {
      p.abortParsing()
      return
    }
    v.text += s
  }
  func parser(_ p: XMLParser, foundCDATA d: Data) {
    if let s = String(data: d, encoding: .utf8) { parser(p, foundCharacters: s) }
  }
  func parser(
    _ parser: XMLParser, didEndElement n: String, namespaceURI: String?, qualifiedName: String?
  ) { _ = stack.popLast() }
}
enum CastProtocol {
  static func device(_ d: Data, url: URL, fixture: Bool = false, alias: String? = nil) throws
    -> CastDevice
  {
    guard CastAddress.safe(url, fixture: fixture) else { throw CastProblem.address }
    let r = try CastXML.parse(d)
    let base: URL
    if let str = r.field("URLBase"), !str.isEmpty {
      guard let u = CastAddress.child(str, from: url, fixture: fixture, alias: alias) else {
        throw CastProblem.address
      }
      base = u
    } else {
      base = url
    }
    for n in r.descendants("device") {
      guard n.field("deviceType")?.hasPrefix("urn:schemas-upnp-org:device:MediaRenderer:") == true,
        let services = n.one("serviceList")
      else { continue }
      func select(_ k: CastKind) -> CastService? {
        services.children.compactMap { e -> (Int, CastService)? in
          guard e.name == "service", let urn = e.field("serviceType"), let v = k.version(urn),
            let raw = e.field("controlURL"),
            let url = CastAddress.child(raw, from: base, fixture: fixture, alias: alias)
          else { return nil }
          return (
            v,
            .init(
              urn: urn, control: url,
              scpd: e.field("SCPDURL").flatMap {
                CastAddress.child($0, from: base, fixture: fixture, alias: alias)
              })
          )
        }.max { $0.0 < $1.0 }?.1
      }
      if let transport = select(.transport) {
        let udn = n.field("UDN")?.prefix(160)
        let name = n.field("friendlyName")?.prefix(120)
        return .init(
          name: name.flatMap { $0.isEmpty ? nil : String($0) } ?? url.host ?? "播放器",
          id: udn.flatMap { $0.isEmpty ? nil : String($0) } ?? transport.control.absoluteString,
          location: url, transport: transport, render: select(.render))
      }
    }
    throw CastProblem.description
  }
  static func capabilities(_ data: Data) throws -> CastCapabilities {
    let r = try CastXML.parse(data)
    guard r.name == "scpd", let list = r.one("actionList") else { throw CastProblem.reply }
    var caps = CastCapabilities(
      actions: Set(
        list.children.compactMap { $0.field("name").flatMap(CastAction.init(rawValue:)) }))
    for v in r.one("serviceStateTable")?.children ?? [] where v.field("name") == "Volume" {
      if let range = v.one("allowedValueRange"), let a = range.field("minimum").flatMap(Int.init),
        let b = range.field("maximum").flatMap(Int.init),
        a >= 0, b > a, b <= 65535
      {
        let s = range.field("step").flatMap(Int.init) ?? 1
        if (1...b - a).contains(s) { caps.volumeRange = .init(min: a, max: b, step: s) }
      }
    }
    return caps
  }
  static func escape(_ s: String) -> String {
    s.unicodeScalars.filter { $0.value >= 32 || [9, 10, 13].contains($0.value) }.map(String.init)
      .joined().replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(
        of: "<", with: "&lt;"
      ).replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }
  static func metadata(title: String, uri: URL, mime: String = "video/mp4") -> String {
    "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\"><item id=\"0\" parentID=\"-1\" restricted=\"1\"><dc:title>"
      + escape(String(title.prefix(250)))
      + "</dc:title><upnp:class>object.item.videoItem</upnp:class><res protocolInfo=\"http-get:*:"
      + escape(mime) + ":*\">" + escape(uri.absoluteString) + "</res></item></DIDL-Lite>"
  }
  static func envelope(_ a: CastAction, service: CastService, fields: [(String, String)]) -> Data {
    let extra = fields.map { "<" + $0.0 + ">" + escape($0.1) + "</" + $0.0 + ">" }.joined()
    return Data(
      ("<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:"
        + a.rawValue + " xmlns:u=\"" + service.urn + "\"><InstanceID>0</InstanceID>" + extra
        + "</u:" + a.rawValue + "></s:Body></s:Envelope>").utf8)
  }
  static func reply(_ d: Data, status: Int, action: CastAction, service: CastService) throws
    -> [String: String]
  {
    let r = try CastXML.parse(d)
    guard r.name == "Envelope", let b = r.one("Body") else { throw CastProblem.reply }
    if let fault = b.one("Fault") {
      let detail = fault.descendants("UPnPError").first
      let code = detail?.field("errorCode").flatMap(Int.init) ?? status
      throw CastProblem.fault(code, String((detail?.field("errorDescription") ?? "").prefix(160)))
    }
    guard (200..<300).contains(status), let res = b.one(action.rawValue + "Response"),
      res.ns == service.urn || res.ns.isEmpty
    else { throw CastProblem.reply }
    var fields = [String: String]()
    for e in res.children {
      fields[e.name] = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return fields
  }
  static func seconds(_ text: String?) -> Double? {
    guard let s = text, s.utf8.count <= 18 else { return nil }
    let p = s.split(separator: ":", omittingEmptySubsequences: false)
    guard p.count == 3, let h = Int(p[0]), let m = Int(p[1]), let t = Double(p[2]),
      (0...9999).contains(h), (0..<60).contains(m), t.isFinite, (0..<60).contains(t)
    else { return nil }
    return Double(h * 3600 + m * 60) + t
  }
  static func time(_ s: Double) -> String {
    let v = s.isFinite ? Int(Swift.max(0, Swift.min(35_999_999, s.rounded(.down)))) : 0
    return String(format: "%02d:%02d:%02d", v / 3600, (v / 60) % 60, v % 60)
  }
}
