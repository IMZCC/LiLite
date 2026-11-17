import Foundation
import Security

enum SponsorIdentity {
  static func key(_ host: URL) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "PiliNative.Sponsor",
      kSecAttrAccount as String: host.absoluteString,
    ]
  }
  static func set(_ id: String, base: URL) throws {
    guard (16...256).contains(id.utf8.count),
      id.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || [45, 95].contains($0)
      })
    else { throw ServiceError("贡献 ID 无效") }
    let q = key(base)
    let value = [kSecValueData as String: Data(id.utf8)]
    let rc = SecItemUpdate(q as CFDictionary, value as CFDictionary)
    if rc == errSecItemNotFound {
      var item = q
      item[kSecValueData as String] = Data(id.utf8)
      item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
        throw ServiceError("未能保存贡献 ID")
      }
    } else if rc != errSecSuccess {
      throw ServiceError("未能保存贡献 ID")
    }
  }
  static func get(_ base: URL) throws -> String {
    var q = key(base)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &item)
    if status == errSecSuccess, let bytes = item as? Data {
      return String(decoding: bytes, as: UTF8.self)
    }
    guard status == errSecItemNotFound else { throw ServiceError("未能读取贡献 ID") }
    var bytes = [UInt8](repeating: 0, count: 16)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw ServiceError("未能建立贡献 ID")
    }
    let id = bytes.map { String(format: "%02x", $0) }.joined()
    try set(id, base: base)
    return id
  }
}
struct SponsorAPI {
  let base: URL
  init(
    _ input: String = UserDefaults.standard.string(forKey: "sponsor.server")
      ?? SponsorAPIRequest.defaultServer
  ) throws {
    guard let u = SelfHostedServiceURL.parse(input) else { throw ServiceError("请填写有效的 HTTP 或 HTTPS 服务地址") }
    base = u
  }
  private func request(
    _ path: String, method: String = "GET", query: [String: String] = [:],
    body: [String: Any]? = nil
  ) async throws -> (Int, Data) {
    let r = try SponsorAPIRequest.make(base: base, path: path, method: method, query: query, body: body)
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    config.httpShouldSetCookies = false
    let delegate = try PrivateServiceDelegate(service:.sponsor,url:base,denyRedirect:false)
    let session = URLSession(configuration:config,delegate:delegate,delegateQueue:nil)
    defer { session.invalidateAndCancel() }
    let (stream, resp) = try await session.bytes(for: r)
    guard let http = resp as? HTTPURLResponse else { throw ServiceError("空降助手响应无效") }
    if http.statusCode == 404 && method == "GET" && ["skipSegments","portVideo"].contains(path) { return (404, Data()) }
    guard http.statusCode == 200 else { throw ServiceError("空降助手请求失败（\(http.statusCode)）") }
    var data = Data()
    for try await b in stream {
      guard data.count < 2 * 1024 * 1024 else { throw ServiceError("空降助手响应过大") }
      data.append(b)
    }
    return (http.statusCode, data)
  }
  func segments(_ bvid: String, _ cid: Int64) async throws -> [SponsorSegment] {
    let (code, d) = try await request("skipSegments", query: ["videoID": bvid, "cid": String(cid)])
    if code == 404 { return [] }
    return try JSONDecoder().decode([SponsorSegment].self, from: d).filter(\.valid).sorted {
      $0.segment[0] < $1.segment[0]
    }
  }
  func viewed(_ uuid: String) async throws {
    _ = try await request("viewedVideoSponsorTime", method: "POST", body: ["UUID": uuid])
  }
  func vote(_ uuid: String, type: Int? = nil, category: String? = nil) async throws {
    guard (type == nil) != (category == nil) else { throw ServiceError("投票无效") }
    var q = ["UUID": uuid, "userID": try SponsorIdentity.get(base)]
    q["type"] = type.map(String.init)
    q["category"] = category
    _ = try await request("voteOnSponsorTime", method: "POST", query: q)
  }
  func originVideo(_ source:SponsorSource) async throws -> String? {
    let (code,data)=try await request("portVideo",query:source.lookup)
    if code==404{return nil}
    let id=try JSONDecoder().decode(SponsorLinkRecord.self,from:data).ytbID
    guard let id,!id.isEmpty else{return nil}
    guard SponsorSource.validID(id) else{throw ServiceError("服务器返回了无效的原视频编号")};return id
  }
  func linkOrigin(_ source:SponsorSource) async throws {
    let (_,data)=try await request("portVideo",method:"POST",body:source.fields(identity:try SponsorIdentity.get(base)))
    guard let uuid=try JSONDecoder().decode(SponsorLinkReceipt.self,from:data).UUID,!uuid.isEmpty,uuid.count<=128 else{throw ServiceError("未收到绑定回执")}
  }
  func status() async throws {
    let (_, d) = try await request("status/uptime")
    guard
      Double(String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        != nil
    else { throw ServiceError("服务器状态无效") }
  }
  struct Stats: Decodable { let viewCount: Int, minutesSaved: Double, segmentCount: Int }
  func stats() async throws -> Stats {
    let (_, d) = try await request(
      "userInfo",
      query: [
        "userID": try SponsorIdentity.get(base),
        "values": #"["viewCount","minutesSaved","segmentCount"]"#,
      ])
    return try JSONDecoder().decode(Stats.self, from: d)
  }
  func publish(bvid: String, cid: Int64, duration: Double, drafts: [SponsorDraft]) async throws
    -> [SponsorSegment]
  {
    let segments = try SponsorDraft.payload(drafts, duration: duration)
    let (_, d) = try await request(
      "skipSegments", method: "POST",
      body: [
        "videoID": bvid, "cid": String(cid), "userID": try SponsorIdentity.get(base),
        "userAgent": "PiliNative/2.2.0.2", "videoDuration": duration,
        "segments": segments,
      ])
    return try JSONDecoder().decode([SponsorSegment].self, from: d).filter(\.valid)
  }
}
