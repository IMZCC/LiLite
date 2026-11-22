import CryptoKit
import Foundation

/// 第三方取流覆盖（实验性），移植自 PiliNara / PiliPlus 的高画质播放。
///
/// 非大会员请求 1080P 以上画质时，B 站会按账号权益降档。启用后把已签名的
/// playurl 请求与当前视频账号的登录态交给用户配置的解析服务，再把远端返回的
/// 高画质轨道合并回本机响应。
enum HighQualityPlayback {
  static let enabledKey = "hq.enabled"
  static let serverKey = "hq.server"
  static let qualityKey = "hq.quality"
  static let alwaysAcceptKey = "hq.alwaysAccept"
  static let desktopUAKey = "hq.desktopUA"

  /// 可选目标画质（1080P 高码率及以上）
  static let qualityOptions = [112, 116, 120, 125, 126, 127]

  static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }
  static var serverURL: String {
    let raw = UserDefaults.standard.string(forKey: serverKey) ?? ""
    return raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
  }
  static var targetQuality: Int {
    let value = UserDefaults.standard.object(forKey: qualityKey) as? Int ?? 116
    return qualityOptions.contains(value) ? value : 116
  }
  static var alwaysAccept: Bool {
    UserDefaults.standard.object(forKey: alwaysAcceptKey) as? Bool ?? true
  }
  static var prefersDesktopUA: Bool {
    UserDefaults.standard.object(forKey: desktopUAKey) as? Bool ?? true
  }

  private(set) static var status = "尚未请求"
  private(set) static var lastRequest = ""
  private(set) static var lastRawResponse = ""
  private(set) static var lastAttempts = ""
  private(set) static var lastErrorCode: Int?
  private(set) static var lastErrorMessage = ""

  static let desktopUserAgent =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    + "(KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36"
  static let appUserAgent =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
    + "Version/17.0 Mobile/15E148 Safari/604.1"

  private static var userAgent: String { prefersDesktopUA ? desktopUserAgent : appUserAgent }
  private static var attempts: [String] = []
  private static var navCache: [String: Nav] = [:]
  private static var cookieExtras: [String: [String: String]] = [:]
  private static var cookieTried = false

  private struct Nav {
    var level = 0, money = 0, vip = 0
  }

  private struct Remote {
    let formats: DashFormats
    let timeLength: Int?
    var playableMilliseconds: Int? {
      if let seconds = formats.duration, seconds > 0 { return seconds * 1000 }
      return nil
    }
    /// 远端给的是不是完整整集（`timelength` 与可播长度差 30 秒以上视为试看）
    var complete: Bool {
      guard let full = timeLength, full > 0, let playable = playableMilliseconds, playable > 0 else {
        return !formats.video.isEmpty
      }
      return full - playable < 30_000
    }
    var durationText: String {
      guard let playable = playableMilliseconds, playable > 0 else { return "" }
      return "\(playable / 60_000) 分 \((playable % 60_000) / 1000) 秒"
    }
  }

  private static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 30
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: config)
  }()

  static func qualityDescription(_ quality: Int) -> String { StreamQuality.name(quality) }

  // MARK: - 普通投稿

  /// 在 `/x/player/wbi/playurl` 返回后调用，把远端更高画质的轨道并入 [formats]。
  static func applyUGCN(
    _ formats: DashFormats, fields: [String: String], owner: String
  ) async -> DashFormats {
    guard await mayRequest(owner: owner) else { return formats }
    await resetAttempts()
    let ui = await accountPayload(owner: owner)
    let target = targetQuality
    let webQn = min(target, 116)

    var remote = await requestUGC(pageParams(fields, qn: webQn), ui: ui)
    record("第 1 次（qn=\(webQn)，页面参数）")
    if remote == nil, shouldRetry {
      setStatus("远端拒绝（\(lastErrorMessage)），改用网页精简参数重试…")
      var query = fields
      query["wbi"] = nil
      query["w_rid"] = nil
      query["wts"] = nil
      query["qn"] = "\(webQn)"
      query["voice_balance"] = nil
      query["cur_language"] = nil
      for key in query.keys where key.hasPrefix("dm_") { query[key] = nil }
      query["from_client"] = "BROWSER"
      query["is_main_page"] = "true"
      query["need_fragment"] = "false"
      query["isGaiaAvoided"] = "false"
      query["web_location"] = "1315873"
      remote = await requestUGC(query, ui: ui)
      record("第 2 次（qn=\(webQn)，网页精简参数）")
    }
    if remote == nil, shouldRetry {
      setStatus("远端仍拒绝，改用 App 参数重试…")
      var query = fields
      query["qn"] = "\(target)"
      remote = await requestUGC(query, ui: ui)
      record("第 3 次（qn=\(target)，App 参数）")
    }
    guard let remote else {
      if lastErrorCode != nil {
        setStatus("远端返回错误(\(lastErrorCode ?? -1))：\(hint(lastErrorCode ?? -1, lastErrorMessage))")
      } else if status == "请求中…" {
        setStatus("远端未返回可用流")
      }
      return formats
    }

    let merged = merge(into: formats, remote: remote, target: target)
    if merged.added.isEmpty {
      setStatus("远端未返回更高画质")
      return formats
    }
    var result = merged.formats
    if remote.complete { result.isPreview = false }
    let names = merged.added.map(qualityDescription).joined(separator: "、")
    setStatus(remote.complete ? "成功：新增 \(names)" : "成功：新增 \(names)（远端为试看片段）")
    return result
  }

  // MARK: - 番剧 / 国创 / 影视

  /// 在 playview 解析完成后调用；本地没有 dash（试看 durl）时直接采用远端完整流。
  static func upgradeEpisode(
    _ info: EpisodePlayPayload.Info, episode: SeasonInfo.Episode, course: Bool,
    language: String?, owner: String, requestedQn: Int
  ) async -> EpisodePlayPayload.Info? {
    guard requestedQn >= 80, await mayRequest(owner: owner) else { return nil }
    await resetAttempts()
    let ui = await accountPayload(owner: owner)
    var fields = episodeFields(
      episode, course: course, language: language, owner: owner, quality: targetQuality)
    fields["voice_balance"] = AudioFilterChoice.requestsProcessing ? "1" : "0"
    guard let url = try? await signedURL("/ogv/player/playview", fields) else {
      setStatus("无法构造番剧取流请求")
      return nil
    }
    guard let remote = await request("/api/bzview3",
      payload: ["iic": false, "url": url, "ui": ui]) else {
      record("bzview3（番剧/影视）")
      if lastErrorCode != nil {
        setStatus("远端返回错误(\(lastErrorCode ?? -1))：\(hint(lastErrorCode ?? -1, lastErrorMessage))")
      }
      return nil
    }
    record("bzview3（番剧/影视）")

    var updated = info
    if let local = info.dash, !local.video.isEmpty {
      let merged = merge(into: local, remote: remote, target: targetQuality)
      guard !merged.added.isEmpty else {
        setStatus("远端未返回更高画质")
        return nil
      }
      updated.dash = merged.formats
      let names = merged.added.map(qualityDescription).joined(separator: "、")
      setStatus(remote.complete ? "成功：新增 \(names)" : "成功：新增 \(names)（远端为试看片段）")
    } else {
      guard !remote.formats.video.isEmpty else {
        setStatus("远端未返回可用流")
        return nil
      }
      updated.dash = remote.formats
      let names = remote.formats.video.map(\.id).sorted(by: >).map(qualityDescription)
        .joined(separator: "、")
      setStatus(remote.complete ? "成功：改用远端完整流（\(names)）" : "成功：改用远端流（\(names)）")
    }
    updated.preview = !remote.complete
    updated.highQualityResolved = remote.complete
    return updated
  }

  // MARK: - 请求

  private static func mayRequest(owner: String) async -> Bool {
    guard enabled else { return false }
    guard !serverURL.isEmpty else {
      status = "未配置服务地址"
      return false
    }
    if !owner.isEmpty {
      let nav = await fetchNav(owner: owner)
      if nav.vip == 1 {
        status = "当前账号是大会员，无需高画质解析"
        return false
      }
    }
    return true
  }

  private static func requestUGC(_ query: [String: String], ui: [String: Any]) async -> Remote? {
    setStatus("请求中…")
    guard let url = try? await signedURL("/x/player/wbi/playurl", query) else {
      lastErrorCode = -1
      lastErrorMessage = "签名失败"
      return nil
    }
    return await request("/api/bzview2", payload: ["ui": ui, "url": url])
  }

  private static func request(_ path: String, payload: [String: Any]) async -> Remote? {
    setStatus("请求中…")
    guard let url = URL(string: serverURL + path) else {
      lastErrorCode = -1
      lastErrorMessage = "服务地址无效"
      return nil
    }
    lastRequest = redacted(payload)
    lastErrorCode = nil
    lastErrorMessage = ""
    var body: Data
    do { body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) }
    catch {
      lastErrorCode = -1
      lastErrorMessage = "请求体无效"
      return nil
    }
    var req = URLRequest(url: url, timeoutInterval: 30)
    req.httpMethod = "POST"
    req.httpBody = body
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    req.setValue("*/*", forHTTPHeaderField: "Accept")
    req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
    req.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
    req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    req.setValue("close", forHTTPHeaderField: "Connection")

    for attempt in 1...2 {
      do {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
          lastErrorCode = -1
          lastErrorMessage = "响应无效"
          return nil
        }
        guard (200..<300).contains(http.statusCode) else {
          lastErrorCode = -1
          lastErrorMessage = "服务返回 HTTP \(http.statusCode)"
          lastRawResponse = lastErrorMessage
          setStatus("连接失败：\(lastErrorMessage)")
          return nil
        }
        return parse(data)
      } catch {
        if attempt == 2 {
          let message = transportHint(error)
          lastErrorCode = -1
          lastErrorMessage = message
          lastRawResponse = message
          setStatus("连接失败：\(message)")
          return nil
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
      }
    }
    return nil
  }

  private static func parse(_ data: Data) -> Remote? {
    let text = String(data: data, encoding: .utf8) ?? ""
    lastRawResponse = clip(text, 3000)
    guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      setStatus("远端返回的不是合法 JSON")
      return nil
    }
    if let code = json["code"] as? Int, code != 0 {
      lastErrorCode = code
      lastErrorMessage = (json["message"] as? String) ?? (json["msg"] as? String) ?? ""
      setStatus("远端返回错误(\(code))：\(hint(code, lastErrorMessage))")
      return nil
    }
    var payload: Any = json["data"] ?? json["result"] ?? json
    if let encoded = payload as? String,
      let nested = try? JSONSerialization.jsonObject(with: Data(encoded.utf8)) {
      payload = nested
    }
    guard var map = payload as? [String: Any] else {
      setStatus("远端返回格式异常")
      return nil
    }
    if let info = map["video_info"] as? [String: Any] { map = info }
    guard map["dash"] != nil || map["durl"] != nil else {
      setStatus("远端返回数据不完整")
      return nil
    }
    var formats: DashFormats?
    if let dash = map["dash"] as? [String: Any],
      let fixed = fixedHosts(dash) as? [String: Any],
      let bytes = try? JSONSerialization.data(withJSONObject: fixed) {
      formats = try? JSONDecoder().decode(DashFormats.self, from: bytes)
    }
    guard let formats else {
      if map["durl"] is [Any] {
        setStatus("远端只返回了分段流（暂不支持）")
      } else {
        setStatus("远端未返回可用流")
      }
      return nil
    }
    if formats.video.isEmpty {
      setStatus("远端未返回分轨视频流")
      return nil
    }
    return Remote(formats: formats, timeLength: map["timelength"] as? Int)
  }

  private static func merge(into formats: DashFormats, remote: Remote, target: Int) -> (formats: DashFormats, added: [Int]) {
    let candidates = remote.formats.video.filter { $0.id <= target }
    guard !candidates.isEmpty else { return (formats, []) }
    let before = Set(formats.video.map(\.id))
    let result = formats.mergingVideo(.init(video: candidates))
    let added = Set(result.video.map(\.id)).subtracting(before).sorted(by: >)
    return (result, added)
  }

  private static func fixedHosts(_ value: Any) -> Any {
    if let text = value as? String {
      return text.replacingOccurrences(of: "-mirrorcosov.", with: "-mirrorcos.")
    }
    if let array = value as? [Any] { return array.map(fixedHosts) }
    if let map = value as? [String: Any] { return map.mapValues(fixedHosts) }
    return value
  }

  private static func pageParams(_ fields: [String: String], qn: Int) -> [String: String] {
    var params: [String: String] = [:]
    for key in ["avid", "bvid", "cid"] where fields[key] != nil { params[key] = fields[key] }
    params["qn"] = "\(qn)"
    params["fnver"] = fields["fnver"] ?? "0"
    params["fnval"] = fields["fnval"] ?? "4048"
    params["fourk"] = fields["fourk"] ?? "1"
    params["gaia_source"] = ""
    params["from_client"] = "BROWSER"
    params["is_main_page"] = "true"
    params["need_fragment"] = "false"
    params["isGaiaAvoided"] = "false"
    params["client_attr"] = "0"
    params["version_name"] = "4.10.6"
    params["app_id"] = "100"
    params["session"] = sessionID()
    params["voice_balance"] = fields["voice_balance"] ?? "1"
    params["try_look"] = "0"
    params["web_location"] = "1315873"
    params["x-bili-device-req-json"] = #"{"platform":"web","device":"pc","mobi_app":"web_cn"}"#
    params["x-bili-locale-json"] =
      #"{"c_locale":{"language":"zh","script":"Hans"},"always_translate":false}"#
    return params
  }

  private static func sessionID() -> String {
    let characters = Array("0123456789abcdef")
    return String((0..<32).map { _ in characters.randomElement()! })
  }

  private static func signedURL(_ path: String, _ query: [String: String]) async throws -> String {
    let signed = try await BiliAPI.shared.sign(query)
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let rendered = signed.keys.sorted().map { key -> String in
      let value = (signed[key] ?? "").filter { !"'!()*".contains($0) }
      let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
      return "\(key)=\(encoded)"
    }.joined(separator: "&")
    return "https://api.bilibili.com\(path)?\(rendered)"
  }

  private static func episodeFields(
    _ episode: SeasonInfo.Episode, course: Bool, language: String?, owner: String,
    quality: Int
  ) -> [String: String] {
    var fields = [
      "ep_id": String(episode.id), "cid": String(episode.cid), "qn": String(quality),
      "fnval": "4048", "fnver": "0", "fourk": "1", "biz_type": course ? "pugv" : "ogv",
      "scene": "normal", "from_client": "BROWSER", "drm_tech_type": "0", "app_id": "100",
    ]
    if let aid = episode.aid { fields["avid"] = String(aid) }
    if !episode.bvid.isEmpty { fields["bvid"] = episode.bvid }
    fields["cur_language"] = language
    fields.merge(ArchiveStreamGrant.requestFields(guest: owner.isEmpty)) { current, _ in current }
    return fields
  }

  // MARK: - 账号信息

  private static func accountPayload(owner: String) async -> [String: Any] {
    let identity = try? await AccountJar.shared.current(.role(.video))
    let cookie = identity?.header ?? ""
    let csrf = identity?.csrf ?? ""
    let nav = owner.isEmpty ? Nav() : await fetchNav(owner: owner)
    var extras = cookieExtras[owner] ?? [:]
    if !cookie.isEmpty, !cookieTried {
      cookieTried = true
      extras = await fillWebCookies(cookie: cookie, csrf: csrf, owner: owner)
    }
    let all = extras.isEmpty
      ? cookie
      : (cookie.isEmpty ? "" : cookie + "; ")
        + extras.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
    return [
      "ua": userAgent,
      "mid": cookieValue("DedeUserID", in: all) ?? owner,
      "vip": nav.vip,
      "level": nav.level,
      "money": nav.money < 1 ? 0 : nav.money,
      "cookie": all,
      "csrf": csrf,
    ]
  }

  private static func cookieValue(_ name: String, in header: String) -> String? {
    for part in header.split(separator: ";") {
      let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
      if pair.count == 2, pair[0] == name { return String(pair[1]) }
    }
    return nil
  }

  private static func fetchNav(owner: String) async -> Nav {
    if let cached = navCache[owner] { return cached }
    guard let identity = try? await AccountJar.shared.current(.role(.video)),
      identity.id == owner else { return Nav() }
    guard let data = await get(
      "https://api.bilibili.com/x/web-interface/nav", cookie: identity.header),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let payload = json["data"] as? [String: Any], payload["isLogin"] as? Bool == true
    else { return Nav() }
    var nav = Nav()
    nav.level = ((payload["level_info"] as? [String: Any])?["current_level"] as? Int) ?? 0
    nav.money = Int((payload["money"] as? NSNumber)?.doubleValue ?? 0)
    nav.vip = payload["vipStatus"] as? Int == 1 ? 1 : 0
    navCache[owner] = nav
    return nav
  }

  private static func fillWebCookies(
    cookie: String, csrf: String, owner: String
  ) async -> [String: String] {
    var extra: [String: String] = [:]
    func has(_ name: String) -> Bool { cookieValue(name, in: cookie) != nil }
    if !has("_uuid") { extra["_uuid"] = "\(randomUUID())infoc" }
    if !has("b_nut") { extra["b_nut"] = "\(Int(Date().timeIntervalSince1970))" }
    if !has("CURRENT_FNVAL") { extra["CURRENT_FNVAL"] = "4048" }
    if !has("buvid4"),
      let data = await get("https://api.bilibili.com/x/frontend/finger/spi", cookie: cookie),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let payload = json["data"] as? [String: Any], let buvid4 = payload["b_4"] as? String,
      !buvid4.isEmpty {
      extra["buvid4"] = buvid4
    }
    if !has("bili_ticket"), !csrf.isEmpty,
      let ticket = await fetchTicket(cookie: cookie, csrf: csrf) {
      extra.merge(ticket) { _, new in new }
    }
    cookieExtras[owner] = extra
    return extra
  }

  private static func fetchTicket(cookie: String, csrf: String) async -> [String: String]? {
    let ts = Int(Date().timeIntervalSince1970)
    let mac = HMAC<SHA256>.authenticationCode(
      for: Data("ts\(ts)".utf8), using: SymmetricKey(data: Data("XgwSnGZ1p".utf8)))
    let sign = mac.map { String(format: "%02x", $0) }.joined()
    guard let url = URL(string:
      "https://api.bilibili.com/bapis/bilibili.api.ticket.v1.Ticket/GenWebTicket"
      + "?key_id=ec02&hexsign=\(sign)&context%5Bts%5D=\(ts)&csrf=\(csrf)")
    else { return nil }
    var req = URLRequest(url: url, timeoutInterval: 10)
    req.setValue(cookie, forHTTPHeaderField: "Cookie")
    req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    req.setValue(appUserAgent, forHTTPHeaderField: "User-Agent")
    guard let (data, _) = try? await session.data(for: req),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let payload = json["data"] as? [String: Any], let ticket = payload["ticket"] as? String,
      !ticket.isEmpty
    else { return nil }
    let created = (payload["created_at"] as? NSNumber)?.intValue ?? ts
    let ttl = (payload["ttl"] as? NSNumber)?.intValue ?? 259_200
    return ["bili_ticket": ticket, "bili_ticket_expires": "\(created + ttl)"]
  }

  private static func get(_ urlString: String, cookie: String) async -> Data? {
    guard let url = URL(string: urlString) else { return nil }
    var req = URLRequest(url: url, timeoutInterval: 10)
    req.setValue(cookie, forHTTPHeaderField: "Cookie")
    req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    req.setValue(appUserAgent, forHTTPHeaderField: "User-Agent")
    return try? await session.data(for: req).0
  }

  private static func randomUUID() -> String {
    let hex = Array("0123456789ABCDEF")
    func block(_ count: Int) -> String {
      String((0..<count).map { _ in hex.randomElement()! })
    }
    let digits = String((0..<5).map { _ in String(Int.random(in: 0...9)) }.joined())
    return "\(block(8))-\(block(4))-\(block(5))-\(block(4))-\(block(12))\(digits)"
  }

  /// 设置页展示当前视频账号（mid / 等级 / 硬币 / 大会员）
  static func accountDescription() async -> String {
    guard let identity = try? await AccountJar.shared.current(.role(.video)) else {
      return "游客（未登录）"
    }
    let nav = await fetchNav(owner: identity.id)
    return "账号 mid=\(identity.id) 等级=\(nav.level) 硬币=\(nav.money) "
      + "大会员=\(nav.vip == 1 ? "是" : "否")"
  }

  // MARK: - 诊断

  private static func resetAttempts() async {
    attempts = []
    lastAttempts = ""
    setStatus("请求中…")
  }

  private static func record(_ label: String) {
    attempts.append(
      "\(label) → " + (lastErrorCode == nil ? "成功" : "code=\(lastErrorCode!) \(lastErrorMessage)"))
    lastAttempts = attempts.joined(separator: "\n")
  }

  private static var shouldRetry: Bool {
    lastErrorCode == 2 && lastErrorMessage == "ignore"
  }

  private static func setStatus(_ value: String) { status = value }

  private static func hint(_ code: Int, _ message: String) -> String {
    if code == 9 { return "次数已达上限，给任意视频投币可重置" }
    switch message {
    case "ignore": return "ignore（服务端判定无需处理，可稍后重试或更换服务地址）"
    case "timeout": return "timeout（服务端请求 B 站超时）"
    case "invalid": return "invalid（服务端认为请求体不合法）"
    case "fail": return "fail（服务端网络失败）"
    case "": return "未知原因"
    default: return message
    }
  }

  private static func transportHint(_ error: Error) -> String {
    let text = error.localizedDescription
    let lower = text.lowercased()
    if lower.contains("reset") { return "连接被对端重置（connection reset）" }
    if lower.contains("timed out") { return "连接超时" }
    if lower.contains("refused") { return "端口未开放（connection refused）" }
    if lower.contains("host") || lower.contains("dns") { return "域名解析失败（检查服务地址）" }
    return text.isEmpty ? "未知连接错误" : text
  }

  private static func redacted(_ payload: [String: Any]) -> String {
    var copy = payload
    if var ui = copy["ui"] as? [String: Any], let cookie = ui["cookie"] as? String {
      let masked = cookie.split(separator: ";").compactMap { part -> String? in
        let pair = part.trimmingCharacters(in: .whitespaces).split(
          separator: "=", maxSplits: 1)
        guard let name = pair.first, !name.isEmpty else { return nil }
        return "\(name)=***"
      }.joined(separator: "; ")
      ui["cookie"] = masked
      copy["ui"] = ui
    }
    guard let data = try? JSONSerialization.data(
      withJSONObject: copy, options: [.sortedKeys, .prettyPrinted]),
      let text = String(data: data, encoding: .utf8) else { return "" }
    return text
  }

  private static func clip(_ text: String, _ max: Int) -> String {
    text.count <= max ? text : String(text.prefix(max)) + "…（共 \(text.count) 字符，已截断）"
  }
}
