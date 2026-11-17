import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
#if canImport(FoundationXML)
  import FoundationXML
#endif

struct DAVLocation {
  let base: URL, file: URL, folders: [URL], collection: URL
  init(address: String, directory: String, tablet: Bool) throws {
    let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = SelfHostedServiceURL.parse(address), let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { throw ServiceError("请输入有效的 HTTP 或 HTTPS 地址") }
    func safe(_ part: String) -> Bool {
      !part.isEmpty && part != "." && part != ".." && !part.contains("/") && !part.contains("\\")
        && !part.contains("%") && part.rangeOfCharacter(from: .controlCharacters) == nil
    }
    for raw in c.percentEncodedPath.split(separator: "/") {
      guard let p = raw.removingPercentEncoding, safe(p) else { throw ServiceError("服务器路径无效") }
    }
    base = url
    if url.pathExtension.lowercased() == "json" && !url.hasDirectoryPath {
      file = url
      folders = []
      collection = url.deletingLastPathComponent()
      return
    }
    let parts = directory.split(separator: "/").map(String.init)
    guard directory.utf8.count <= 2048, parts.count <= 24, parts.allSatisfy(safe) else {
      throw ServiceError("备份目录无效")
    }
    var parent = url
    var result: [URL] = []
    for part in parts + ["PiliPlus"] {
      parent = parent.appendingPathComponent(part, isDirectory: true)
      result.append(parent)
    }
    collection = parent
    folders = result
    file = parent.appendingPathComponent(
      tablet ? "piliplus_settings_pad.json" : "piliplus_settings_phone.json")
  }
}

private final class DAVCollectionParser: NSObject, XMLParserDelegate {
  private var stack: [String] = [], status = "", isCollection = false
  private(set) var found = false
  static func check(_ data: Data) -> Bool {
    guard data.count <= 1024 * 1024, !data.contains(0),
      data.range(of: Data("<!DOCTYPE".utf8)) == nil, data.range(of: Data("<!ENTITY".utf8)) == nil
    else { return false }
    let delegate = DAVCollectionParser()
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    return parser.parse() && delegate.found
  }
  func parser(
    _ parser: XMLParser, didStartElement name: String, namespaceURI ns: String?,
    qualifiedName: String?, attributes: [String: String]
  ) {
    stack.append(ns == "DAV:" ? name : "")
    if stack.suffix(3).elementsEqual(["multistatus", "response", "propstat"]) {
      status = ""
      isCollection = false
    }
    if stack.suffix(4).elementsEqual(["propstat", "prop", "resourcetype", "collection"]) {
      isCollection = true
    }
  }
  func parser(_ parser: XMLParser, foundCharacters s: String) {
    if stack.suffix(2).elementsEqual(["propstat", "status"]) { status += s }
  }
  func parser(
    _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
  ) {
    if stack.elementsEqual(["multistatus", "response", "propstat"]), isCollection,
      status.split(whereSeparator: \.isWhitespace).dropFirst().first == "200"
    {
      found = true
    }
    _ = stack.popLast()
  }
}

struct DAVReply {
  let status: Int, data: Data
  var etag: String? = nil, modified: String? = nil, date: String? = nil
}
struct DAVStore {
  typealias Send = (URLRequest) async throws -> DAVReply
  let location: DAVLocation, user: String, password: String, send: Send
  private func request(
    _ verb: String, _ url: URL, body: Data? = nil, headers: [String: String] = [:]
  ) async throws -> DAVReply {
    #if os(iOS)
    let done = ["PUT","DELETE","MKCOL","MOVE","COPY"].contains(verb.uppercased()) ? try SleepExitFence.shared.enter() : nil
    defer { done?() }
    #endif
    guard SelfHostedServiceURL.sameOrigin(url, location.base),
      url.query == nil, url.fragment == nil,
      url == location.file || url == location.collection || location.folders.contains(url)
        || managedURL(url.absoluteString) == url
    else { throw ServiceError("远程文件不在所选备份目录") }
    var req = URLRequest(url: url, timeoutInterval: 20)
    req.httpMethod = verb
    req.httpBody = body
    req.httpShouldHandleCookies = false
    if !user.isEmpty {
      guard !user.contains(":"), user.rangeOfCharacter(from: .controlCharacters) == nil else {
        throw ServiceError("用户名无效")
      }
      req.setValue(
        "Basic " + Data((user + ":" + password).utf8).base64EncodedString(),
        forHTTPHeaderField: "Authorization")
    }
    for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
    return try await send(req)
  }
  private func fail(_ code: Int) -> ServiceError {
    switch code {
    case 401, 403: return ServiceError("服务器拒绝访问，请检查账号和权限（\(code)）")
    case 404: return ServiceError("未找到远程备份")
    case 412: return ServiceError("远程备份已更改，请重新备份")
    case 300..<400: return ServiceError("服务器地址发生跳转，请填写最终地址")
    default: return ServiceError("WebDAV 请求失败（\(code)）")
    }
  }
  private func probe(_ path: URL) async throws -> Bool {
    let reply = try await request(
      "PROPFIND", path,
      body: Data(
        #"<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>"#
          .utf8),
      headers: ["Depth": "0", "Content-Type": "application/xml; charset=utf-8"])
    if reply.status == 404 { return false }
    guard reply.status == 207 else { throw fail(reply.status) }
    guard DAVCollectionParser.check(reply.data) else { throw ServiceError("目标路径不是 WebDAV 目录") }
    return true
  }
  func prepare() async throws {
    if location.folders.isEmpty {
      guard try await probe(location.collection) else { throw ServiceError("远程文件目录不存在") }
      return
    }
    for folder in location.folders {
      if try await probe(folder) { continue }
      let reply = try await request("MKCOL", folder)
      if reply.status == 201 { continue }
      if reply.status == 405, try await probe(folder) { continue }
      throw fail(reply.status)
    }
  }
  func read() async throws -> Data {
    let r = try await request("GET", location.file)
    guard r.status == 200 else { throw fail(r.status) }
    return r.data
  }
  func write(merging: (Data?) throws -> Data) async throws {
    try await prepare()
    let current = try await request("GET", location.file)
    var headers = ["Content-Type": "application/json; charset=utf-8"]
    let existing: Data?
    switch current.status {
    case 404:
      headers["If-None-Match"] = "*"
      existing = nil
    case 200:
      guard
        let condition = DAVEntry(
          url: location.file, etag: current.etag, modified: current.modified, size: nil
        ).overwriteCondition(responseDate: current.date)
      else {
        throw ServiceError("无法核实远程备份版本，请稍后重试或另存新备份")
      }
      headers.merge(condition) { _, new in new }
      existing = current.data
    default: throw fail(current.status)
    }
    let bytes = try merging(existing)
    let r = try await request("PUT", location.file, body: bytes, headers: headers)
    guard [200, 201, 204].contains(r.status) else { throw fail(r.status) }
  }
}

struct DAVEntry: Identifiable {
  let url: URL, etag: String?, modified: String?, size: Int?
  var id: String { url.absoluteString }
  var name: String { url.lastPathComponent }
  var encrypted: Bool { url.pathExtension == "pilipack" }
  func overwriteCondition(responseDate: String?) -> [String:String]? {
    guard let guardFields = condition else { return nil }
    if guardFields["If-Match"] != nil { return guardFields }
    // Whole-second dates cannot distinguish two concurrent writes made in that second.
    guard let modified, let date = responseDate, date.count == 29, modified.count == 29 else { return nil }
    let httpDate = DateFormatter()
    httpDate.locale = Locale(identifier: "en_US_POSIX")
    httpDate.timeZone = TimeZone(secondsFromGMT: 0)
    httpDate.calendar = Calendar(identifier: .gregorian)
    httpDate.dateFormat = "EEE',' dd MMM yyyy HH:mm:ss 'GMT'"
    httpDate.isLenient = false
    guard let a = httpDate.date(from: modified), let b = httpDate.date(from: date),
      httpDate.string(from: a) == modified, httpDate.string(from: b) == date,
      b.timeIntervalSince(a) >= 60 else { return nil }
    return guardFields
  }
  var deletionCondition: [String: String]? {
    condition.flatMap { $0["If-Match"] != nil ? $0 : nil }
  }
  var condition: [String: String]? {
    if let t = etag, t.utf8.count <= 256, t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\""),
      t.dropFirst().dropLast().utf8.allSatisfy({ $0 >= 33 && $0 <= 126 && $0 != 34 })
    {
      return ["If-Match": t]
    }
    if let d = modified, d.utf8.count <= 48,
      d.range(
        of: #"^[A-Za-z]{3}, [0-9]{2} [A-Za-z]{3} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT$"#,
        options: .regularExpression) != nil
    {
      return ["If-Unmodified-Since": d]
    }
    return nil
  }
}
private final class DAVFileListParser: NSObject, XMLParserDelegate {
  var fields: [String: String] = [:], prop: [String: String] = [:], result: [[String: String]] = []
  var stack: [String] = [], chars = "", directory = false, verified = false
  static func items(_ data: Data) throws -> [[String: String]] {
    guard data.count <= 1024 * 1024, !data.contains(0),
      data.range(of: Data("<!DOCTYPE".utf8)) == nil,
      data.range(of: Data("<!ENTITY".utf8)) == nil
    else { throw ServiceError("远程目录响应无效") }
    let parser = XMLParser(data: data)
    let d = DAVFileListParser()
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    parser.delegate = d
    guard parser.parse(), d.verified else { throw ServiceError("无法解析 WebDAV 目录") }
    return d.result
  }
  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String]
  ) {
    stack.append(namespaceURI == "DAV:" ? elementName : "")
    guard stack.count < 32, result.count < 2000 else {
      parser.abortParsing()
      return
    }
    chars = ""
    if stack == ["multistatus"] { verified = true }
    if stack == ["multistatus", "response"] {
      fields = [:]
      directory = false
    }
    if stack.suffix(2).elementsEqual(["response", "propstat"]) { prop = [:] }
    if stack.suffix(3).elementsEqual(["prop", "resourcetype", "collection"]) {
      prop["collection"] = "true"
    }
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) {
    chars += string
    if chars.utf8.count > 8192 { parser.abortParsing() }
  }
  func parser(
    _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
  ) {
    defer {
      _ = stack.popLast()
      chars = ""
    }
    let text = chars.trimmingCharacters(in: .whitespacesAndNewlines)
    if stack == ["multistatus", "response", "href"] { fields["href"] = text }
    if stack.suffix(2).elementsEqual(["propstat", "status"]) { prop["status"] = text }
    if stack.dropLast().last == "prop",
      ["getetag", "getcontentlength", "getlastmodified"].contains(stack.last ?? "")
    {
      prop[name] = text
    }
    if stack.suffix(2).elementsEqual(["response", "propstat"]),
      prop["status"]?.split(whereSeparator: \.isWhitespace).dropFirst().first == "200"
    {
      fields.merge(prop) { _, b in b }
      directory = directory || prop["collection"] == "true"
      fields["ok"] = "yes"
    }
    if stack == ["multistatus", "response"], !directory, fields["ok"] == "yes" {
      result.append(fields)
    }
  }
}
extension DAVStore {
  func managedURL(_ href: String) -> URL? {
    guard href.utf8.count <= 4096, !href.contains("\\"), !href.contains("?"), !href.contains("#"),
      href.rangeOfCharacter(from: .controlCharacters) == nil,
      let relative = URLComponents(string: href),
      relative.percentEncodedPath.split(separator: "/").allSatisfy({ raw in
        guard let p = raw.removingPercentEncoding else { return false }
        return p != "." && p != ".." && !p.contains("/") && !p.contains("\\") && !p.contains("%")
      }), let u = URL(string: href, relativeTo: location.collection)?.absoluteURL,
      SelfHostedServiceURL.sameOrigin(u, location.base),
      u.query == nil, u.fragment == nil, !u.hasDirectoryPath
    else { return nil }
    if location.folders.isEmpty { return u.pathComponents == location.file.pathComponents ? location.file : nil }
    let n = u.lastPathComponent
    guard
      [
        "piliplus_settings_phone.json", "piliplus_settings_pad.json",
        "piliplus_settings_desktop.json",
      ].contains(n)
        || n.range(
          of:
            #"^PiliNative-[0-9]{8}T[0-9]{6}Z-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.(json|pilipack)$"#,
          options: .regularExpression) != nil
    else { return nil }
    let safe = location.collection.appendingPathComponent(n)
    return safe.pathComponents == u.pathComponents ? safe : nil
  }
  func contents() async throws -> [DAVEntry] {
    if location.folders.isEmpty {
      let r = try await request("HEAD", location.file)
      if r.status == 404 { return [] }
      guard r.status == 200 else { throw fail(r.status) }
      return [.init(url: location.file, etag: r.etag, modified: r.modified, size: nil)]
    }
    let r = try await request(
      "PROPFIND", location.collection,
      body: Data(
        #"<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getetag/><d:getlastmodified/><d:getcontentlength/></d:prop></d:propfind>"#
          .utf8),
      headers: ["Depth": "1", "Content-Type": "application/xml; charset=utf-8"])
    if r.status == 404 { return [] }
    guard r.status == 207 else { throw fail(r.status) }
    var seen = Set<URL>()
    return try DAVFileListParser.items(r.data).compactMap { f in
      guard let href = f["href"], let u = managedURL(href), seen.insert(u).inserted else {
        return nil
      }
      return DAVEntry(
        url: u, etag: f["getetag"], modified: f["getlastmodified"],
        size: f["getcontentlength"].flatMap(Int.init))
    }.sorted { $0.name > $1.name }
  }
  func read(_ item: DAVEntry) async throws -> Data {
    guard let u = managedURL(item.url.absoluteString) else { throw ServiceError("无效的备份文件") }
    let r = try await request("GET", u, headers: item.condition ?? [:])
    guard r.status == 200 else { throw fail(r.status) }
    if let expected = item.condition?["If-Match"], let actual = r.etag, actual != expected {
      throw fail(412)
    }
    return r.data
  }
  func delete(_ item: DAVEntry) async throws {
    guard let u = managedURL(item.url.absoluteString), let guardHeaders = item.deletionCondition
    else { throw ServiceError("未获得远程文件版本，无法删除") }
    let r = try await request("DELETE", u, headers: guardHeaders)
    guard [200, 204].contains(r.status) else { throw fail(r.status) }
  }
  func snapshot(_ bytes: Data, encrypted: Bool) async throws {
    guard !location.folders.isEmpty else { throw ServiceError("保存多个备份需要填写目录地址") }
    if encrypted {
      guard bytes.starts(with: Data([80, 73, 76, 73, 80, 65, 67, 75, 1])), bytes.count > 53,
        bytes.count <= 64 * 1024 * 1024 + 53
      else { throw ServiceError("必须上传加密数据包") }
    } else {
      let root = try BackupFormat.read(bytes)
      guard let box = root["setting"] as? BackupFormat.Map, root["video"] is BackupFormat.Map,
        Set(box.keys).isDisjoint(with: BackupFormat.forbidden)
      else { throw ServiceError("请选择不含登录凭据的设置文件") }
    }
    try await prepare()
    let date = DateFormatter()
    date.locale = Locale(identifier: "en_US_POSIX")
    date.timeZone = TimeZone(secondsFromGMT: 0)
    date.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    let name =
      "PiliNative-" + date.string(from: Date()) + "-" + UUID().uuidString
      + (encrypted ? ".pilipack" : ".json")
    let r = try await request(
      "PUT", location.collection.appendingPathComponent(name), body: bytes,
      headers: [
        "Content-Type": encrypted ? "application/octet-stream" : "application/json; charset=utf-8",
        "If-None-Match": "*",
      ])
    guard [200, 201, 204].contains(r.status) else { throw fail(r.status) }
  }
}
