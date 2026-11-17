import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum DeviceActivation {
  static let path = "/x/internal/gaia-gateway/ExClimbWuzhi"
  static let url = URL(string: "https://api.bilibili.com" + path)!
  static let fingerURL = URL(string: "https://api.bilibili.com/x/frontend/finger/spi")!
  struct Snapshot: Sendable {
    let owner: String?, device: String, cookie: String, credential: String, routing: String
    let generation: UInt64
    struct Identity: Hashable, Sendable { let owner: String?, device: String, credential: String }
    var identity: Identity { .init(owner: owner, device: device, credential: credential) }
    func matches(_ other: Self) -> Bool {
      identity == other.identity && routing == other.routing
    }
  }
  struct Payload: Sendable {
    let platform: String, entropy: Data
    func data() throws -> Data {
      guard !platform.isEmpty, platform.utf8.count <= 256,
        !platform.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
        entropy.count == 36
      else { throw ServiceError("设备信息暂不可用") }
      // The upstream canvas value is generated noise, not an image captured from the device.
      let png = Data(entropy.prefix(32)) + Data([0, 0, 0, 0, 73, 69, 78, 68]) + Data(entropy.suffix(4))
      let fields: [String: Any] = ["3064": 1, "39c8": "333.1387.fp.risk",
        "3c43": ["adca": platform, "bfe9": String(png.base64EncodedString().suffix(50))]]
      let nested = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
      return try JSONSerialization.data(withJSONObject: ["payload": String(decoding: nested, as: UTF8.self)], options: [.sortedKeys])
    }
  }
  struct Response: @unchecked Sendable {
    let data: Data, status: Int, cookies: [HTTPCookie]
    let url: URL?
    init(data: Data, status: Int, cookies: [HTTPCookie], url: URL? = nil) {
      self.data = data; self.status = status; self.cookies = cookies; self.url = url
    }
  }
  static func request(_ payload: Payload, snapshot: Snapshot) throws -> URLRequest {
    guard MobileDeviceID.valid(snapshot.device), !snapshot.cookie.utf8.contains(where: { $0 < 32 || $0 == 127 })
    else { throw ServiceError("设备信息暂不可用") }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
    request.httpMethod = "POST"; request.httpShouldHandleCookies = false
    request.httpBody = try payload.data()
    request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
    request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    request.setValue("PiliPlus Native (" + payload.platform + ")", forHTTPHeaderField: "User-Agent")
    request.setValue(snapshot.device, forHTTPHeaderField: "buvid")
    if !snapshot.cookie.isEmpty { request.setValue(snapshot.cookie, forHTTPHeaderField: "Cookie") }
    if let owner = snapshot.owner { request.setValue(owner, forHTTPHeaderField: "x-bili-mid") }
    return request
  }
  static func fingerRequest() -> URLRequest {
    var request = URLRequest(url: fingerURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
    request.httpMethod = "GET"; request.httpShouldHandleCookies = false
    request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    request.setValue("PiliPlus Native", forHTTPHeaderField: "User-Agent")
    return request
  }
  static func fingerCookies(_ response: Response, now: Date = Date()) throws -> [HTTPCookie] {
    struct Seed: Decodable { let b_3: String, b_4: String }
    struct Ack: Decodable { let code: Int, data: Seed? }
    guard response.status == 200, response.data.count <= 1024 * 1024,
      let ack = try? JSONDecoder().decode(Ack.self, from: response.data), ack.code == 0, let seed = ack.data
    else { throw ServiceError("设备信息暂不可用") }
    let fields = ["buvid3": seed.b_3, "buvid4": seed.b_4, "b_nut": String(Int64(now.timeIntervalSince1970))]
    return try fields.map { name, value in
      guard !value.isEmpty, value.utf8.count <= 1024,
        value.utf8.allSatisfy({ (33...126).contains($0) && ![34, 59, 92].contains($0) }),
        let cookie = HTTPCookie(properties: [.name: name, .value: value, .domain: ".bilibili.com", .path: "/", .secure: "TRUE"])
      else { throw ServiceError("设备信息暂不可用") }
      return cookie
    }
  }
  static func check(_ response: Response) throws {
    struct Ack: Decodable { let code: Int, message: String?, msg: String? }
    guard response.status == 200, response.data.count <= 1024 * 1024,
      let ack = try? JSONDecoder().decode(Ack.self, from: response.data)
    else { throw ServiceError("设备验证服务暂不可用") }
    guard ack.code == 0 else { throw ServiceError(ack.message ?? ack.msg ?? "设备验证未完成", code: ack.code) }
  }
}

/// Completion is per account/session and device, not per unrelated account-store edit.
actor DeviceActivationClient {
  typealias Snapshot = DeviceActivation.Snapshot
  private struct Pending { let id: UUID, snapshot: Snapshot, task: Task<Snapshot, Error> }
  private var completed = Set<Snapshot.Identity>()
  private var pending: [Snapshot.Identity: Pending] = [:]
  func retain(_ snapshots: [Snapshot]) {
    let live = Set(snapshots.map(\.identity))
    for key in pending.keys.filter({ !live.contains($0) }) {
      pending.removeValue(forKey: key)?.task.cancel()
    }
  }
  func activate(
    _ snapshot: Snapshot,
    payload: @escaping @Sendable () async throws -> DeviceActivation.Payload,
    current: @escaping @Sendable (Snapshot) async throws -> Snapshot,
    send: @escaping @Sendable (URLRequest) async throws -> DeviceActivation.Response,
    commit: @escaping @Sendable (Snapshot, DeviceActivation.Response) async throws -> Snapshot
  ) async throws -> Bool {
    let key = snapshot.identity
    if completed.contains(key) { return false }
    if let existing = pending[key] {
      if existing.snapshot.matches(snapshot) { _ = try await existing.task.value; return false }
      existing.task.cancel(); pending.removeValue(forKey: key)
    }
    let id = UUID()
    let task = Task {
      try Task.checkCancellation()
      guard snapshot.matches(try await current(snapshot)) else { throw CancellationError() }
      let request = try DeviceActivation.request(await payload(), snapshot: snapshot)
      try Task.checkCancellation()
      guard snapshot.matches(try await current(snapshot)) else { throw CancellationError() }
      let response = try await send(request)
      try Task.checkCancellation()
      guard snapshot.matches(try await current(snapshot)) else { throw CancellationError() }
      // Valid Set-Cookie may rotate the same account's session; commit returns its new binding.
      let updated = try await commit(snapshot, response)
      try Task.checkCancellation()
      guard updated.owner == snapshot.owner, updated.device == snapshot.device,
        updated.matches(try await current(updated)) else { throw CancellationError() }
      try DeviceActivation.check(response)
      return updated
    }
    pending[key] = .init(id: id, snapshot: snapshot, task: task)
    do {
      let updated = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
      guard pending[key]?.id == id else { throw CancellationError() }
      pending.removeValue(forKey: key)
      completed.insert(updated.identity)
      return true
    } catch {
      if pending[key]?.id == id { pending.removeValue(forKey: key) }
      throw error
    }
  }
}
