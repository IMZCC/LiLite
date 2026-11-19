import CryptoKit
import Foundation

actor BiliAPI {
  static let shared = BiliAPI()
  private var apiSession: URLSession?
  private var networkProfile: APIProxy?
  var session: BiliServiceSession {
    let profile = APIProxy.current()
    if profile == networkProfile, let apiSession { return .init(native: apiSession, proxy: profile) }
    let config = URLSessionConfiguration.ephemeral
    profile.apply(to: config)
    config.urlCredentialStorage = nil
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCache = nil
    let next = URLSession(configuration: config, delegate: APIRedirectPolicy(), delegateQueue: nil)
    apiSession?.finishTasksAndInvalidate()
    apiSession = next
    networkProfile = profile
    return .init(native: next, proxy: profile)
  }
  private var key: (String, Date)?
  private let agent =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1"
  private struct Envelope<T: Decodable>: Decodable {
    let code: Int
    let message: String?
    let data: T?
    let result: T?
  }
  func fetch(
    _ path: String, _ query: [String: String], host: String, expectedAccount: String? = nil,
    cacheVideoIdentity: Bool = false
  ) async throws -> Data {
    guard
      [
        "api.bilibili.com", "api.live.bilibili.com", "api.vc.bilibili.com", "message.bilibili.com",
        "app.bilibili.com", "www.bilibili.com",
      ]
      .contains(host)
    else { throw URLError(.unsupportedURL) }
    var c = URLComponents()
    c.scheme = "https"
    c.host = host
    c.path = path
    c.queryItems = query.sorted { $0.key < $1.key }.map(URLQueryItem.init)
    guard let url = c.url else { throw URLError(.badURL) }
    var req = URLRequest(url: url, timeoutInterval: 18)
    req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    req.setValue(agent, forHTTPHeaderField: "User-Agent")
    if cacheVideoIdentity {
      guard host == "api.bilibili.com", expectedAccount != nil,
        [
          "/pgc/view/web/season", "/pugv/view/web/season", "/pugv/view/web/season/v2", "/x/web-interface/nav",
          "/x/web-interface/wbi/view",
          "/pgc/player/web/v2/playurl", "/pugv/player/web/playurl",
        ].contains(path)
      else { throw URLError(.unsupportedURL) }
    }
    let role: AccountUse =
      cacheVideoIdentity ? .role(.video) : AccountRoutes.service(path, host: host)
    if host == "app.bilibili.com" {
      return try await mobileREST(path, query, use: role, expectedAccount: expectedAccount).data
    }
    let active = try await AccountJar.shared.webSession(role)
    if let expectedAccount, (active.owner ?? "") != expectedAccount { throw ServiceError("账号已切换") }
    if MobileDeviceID.forRead(host: host, path: path) {
      req.setValue(active.device, forHTTPHeaderField: "buvid")
    }
    req.setValue(active.header(for: url), forHTTPHeaderField: "Cookie")
    let original = req
    let (data, response) = try await ConnectionRetry.current().perform(readOnly: !HTTP11Message.mutatingGET(path)) { index in
      var request = original
      if index > 0 {
        let fresh = try await AccountJar.shared.webSession(role)
        guard fresh.sameIdentity(as: active) else { throw ServiceError("账号已切换") }
        request.setValue(fresh.header(for: url), forHTTPHeaderField: "Cookie")
        if MobileDeviceID.forRead(host: host, path: path) { request.setValue(fresh.device, forHTTPHeaderField: "buvid") }
      }
      let fresh = try await AccountJar.shared.webSession(role)
      guard fresh.sameIdentity(as: active) else { throw ServiceError("账号已切换") }
      return try await self.webResponse(request, bound: fresh, use: role)
    }
    guard response.statusCode == 200 else {
      throw ServiceError("请求未成功（\(response.statusCode)）")
    }
    if let expectedAccount, (try await AccountJar.shared.webSession(role).owner ?? "") != expectedAccount {
      throw ServiceError("账号已切换")
    }
    return data
  }
  func read<T: Decodable>(
    _ path: String, _ q: [String: String], host: String = "api.bilibili.com",
    expectedAccount: String? = nil, as: T.Type
  ) async throws -> T {
    let bytes = try await fetch(path, q, host: host, expectedAccount: expectedAccount)
    do {
      // On error Bilibili sometimes returns a different shape for data.
      let status = try JSONDecoder().decode(Status.self, from: bytes)
      guard status.code == 0 else {
        DiagnosticJournal.network(path, "服务返回", status.code)
        throw ServiceError.readFailure(path,fields:q,code:status.code,message:status.message ?? "请求失败（\(status.code)）")
      }
    }
    let envelope = try JSONDecoder().decode(Envelope<T>.self, from: bytes)
    guard let payload = envelope.data ?? envelope.result
    else { throw ServiceError("没有返回数据") }
    return payload
  }
  private struct Status: Decodable {
    let code: Int
    let message: String?
  }
  func sign(_ query: [String: String]) async throws -> [String: String] {
    let mix: String
    if let (value, date) = key, Calendar.current.isDateInToday(date) {
      mix = value
    } else {
      let nav = try JSONDecoder().decode(
        Envelope<WebQuery.Keys>.self,
        from: try await fetch("/x/web-interface/nav", [:], host: "api.bilibili.com"))
      guard let img = nav.data?.wbi_img else { throw ServiceError("无法取得视频服务参数") }
      mix = try WebQuery.mix(img)
      key = (mix, Date())
    }
    return WebQuery.signed(query, mix: mix) { data in
      Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
  }
  enum FormService: String {
    case main = "api.bilibili.com"
    case live = "api.live.bilibili.com"
    case space = "space.bilibili.com"
  }
  func submit(
    _ path: String, _ fields: [String: String], expectedAccount: String? = nil,
    service: FormService = .main
  ) async throws {
    _ = try await submitResponse(path, fields, expectedAccount: expectedAccount, service: service)
  }
  func submitResponse(
    _ path: String, _ fields: [String: String], expectedAccount: String? = nil,
    service: FormService = .main
  ) async throws -> Data {
    let use = AccountRoutes.service(path, host: service.rawValue)
    let user = try await AccountJar.shared.webSession(use)
    guard let owner = user.owner else { throw ServiceError("请先登录") }
    if let expectedAccount, expectedAccount != owner { throw ServiceError("账号已切换") }
    guard path.hasPrefix("/"), let url = URL(string: "https://" + service.rawValue + path),
      url.host == service.rawValue
    else { throw URLError(.badURL) }
    guard let csrf = user.csrf(for: url) else { throw ServiceError("请先登录") }
    let dynamicComplaint = service == .main && path == "/x/dynamic/feed/dynamic_report/add"
    let targetURL =
      dynamicComplaint ? url.appending(queryItems: [.init(name: "csrf", value: csrf)]) : url
    var req = URLRequest(url: targetURL, timeoutInterval: 18)
    req.httpMethod = "POST"
    req.setValue(
      "application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
    req.setValue(user.header(for: targetURL), forHTTPHeaderField: "Cookie")
    req.setValue(agent, forHTTPHeaderField: "User-Agent")
    req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let f = fields.merging(service == .live ? ["csrf": csrf, "csrf_token": csrf] : ["csrf": csrf]) {
      _, v in v
    }
    req.httpBody = Data(
      f.keys.sorted().map { k in
        k + "=" + (f[k]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
      }.joined(separator: "&").utf8)
    let (d, res) = try await webResponse(req, bound: user, use: use)
    guard res.statusCode == 200 else { throw ServiceError("服务器未接受请求") }
    if service == .space && path == "/ajax/report/add" {
      struct Result: Decodable {
        let status: Bool
        let message: String?
      }
      let result = try JSONDecoder().decode(Result.self, from: d)
      guard result.status else { throw ServiceError(result.message ?? "举报未提交") }
      return d
    }
    let status = try JSONDecoder().decode(Status.self, from: d)
    guard status.code == 0 else {
      DiagnosticJournal.network(path, "操作返回", status.code)
      throw ServiceError(status.message ?? "操作未成功",code:status.code)
    }
    return d
  }
  func recommendations(_ page: Int, mobile: Bool? = nil) async throws -> Page<Video> {
    if mobile ?? (UserDefaults.standard.object(forKey: "feed.mobile") as? Bool ?? true) {
      let r = try await read(
        "/x/v2/feed/index", MobileFeed.fields(page: page), host: "app.bilibili.com",
        as: MobileFeed.self)
      // The original's recommendation feed never ends; an empty page just asks again.
      return Page(items: r.items.compactMap(\.video), next: String(page + 1))
    }
    struct Feed: Decodable {
      struct Item: Decodable {
        let video: Video?
        enum CodingKeys: String, CodingKey { case goto }
        init(from decoder: Decoder) throws {
          let c = try decoder.container(keyedBy: CodingKeys.self)
          video =
            try c.decodeIfPresent(String.self, forKey: .goto) == "av"
            ? try Video(from: decoder) : nil
        }
      }
      let item: [Item]
    }
    // Pages are counted from 1 here; the original's first web request uses fresh_idx 0.
    let idx = max(0, page - 1)
    let q = try await sign([
      "version": "1", "feed_version": "V8", "homepage_ver": "1", "ps": "20", "fresh_idx": "\(idx)",
      "brush": "\(idx)", "fresh_type": "4",
    ])
    let items = try await read("/x/web-interface/wbi/index/top/feed/rcmd", q, as: Feed.self).item
    return Page(items: items.compactMap(\.video), next: "\(page+1)")
  }
  func popular(_ page: Int) async throws -> Page<Video> {
    struct List: Decodable { let list: [Video] }
    let items = try await read(
      "/x/web-interface/popular", ["pn": "\(page)", "ps": "20"], as: List.self
    ).list
    return Page(items: items, next: items.count < 20 ? nil : "\(page+1)")
  }
  func detail(_ bvid: String) async throws -> Video {
    try await read("/x/web-interface/wbi/view", try await sign(["bvid": bvid]), as: Video.self)
  }
  func playback(_ bvid: String, cid: Int64, expectedAccount: String? = nil, forExport: Bool = false) async throws
    -> PlaybackSource
  {
    struct Play: Decodable {
      struct Link: Decodable {
        let url: String
        let backup_url: [String]?
      }
      let quality: Int?
      let durl: [Link]?, volume: AudioMeasurements?
    }
    let owner = try await AccountJar.shared.current(.role(.video))?.id ?? ""
    if let expectedAccount, owner != expectedAccount { throw ServiceError("视频账号已切换") }
    var fields = [
      "bvid": bvid, "cid": "\(cid)", "qn": "64", "fnval": "1", "platform": "html5",
      "voice_balance": AudioFilterChoice.requestsProcessing ? "1" : "0",
    ]
    fields.merge(ArchiveStreamGrant.requestFields(guest: owner.isEmpty)) { current, _ in current }
    let packet = try await read(
      "/x/player/wbi/playurl", try await sign(fields), expectedAccount: owner,
      as: ArchiveGrantResponse<Play>.self)
    let p = packet.body
    guard !packet.grant.protected, !forExport || packet.grant.permitsCache,
      packet.grant.permits(p.quality ?? 0, guest: owner.isEmpty) else {
      throw ServiceError("当前账号没有可用于此操作的视频")
    }
    guard let clips = p.durl, clips.count == 1, let first = clips.first,
      let ref = URL(string: "https://www.bilibili.com/video/\(bvid)/")
    else {
      throw ServiceError("这个视频没有可用的 MP4 播放地址")
    }
    let routes = VODLine.current(([first.url] + (first.backup_url ?? [])).compactMap(httpsURL))
    guard let url = routes.first else { throw ServiceError("这个视频没有可用的 MP4 播放地址") }
    return PlaybackSource(
      preview: packet.grant.preview, volume: p.volume, url: url, backups: Array(routes.dropFirst()), quality: p.quality ?? 0,
      reference: ref)
  }
  func comments(_ cid: Int64) async throws -> [Bullet] {
    try DanmakuXML.parse(
      await fetch("/x/v1/dm/list.so", ["oid": "\(cid)"], host: "api.bilibili.com"))
  }
}
