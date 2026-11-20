import Foundation

/// A Geetest registration from the passport service. Requests that carry the `buvid` header are
/// now given Geetest v4 (`recaptcha_type`/`ct` "geetest4"): `gt` is then a v4 captcha id, which
/// the v3 script reports as `error_34`, and the challenge is unused.
struct MobileCaptcha: Identifiable, Equatable {
  let id = UUID()
  let gt: String, challenge: String, token: String, v4: Bool
  init(gt: String, challenge: String, token: String, v4: Bool = false) throws {
    guard !gt.isEmpty, v4 || !challenge.isEmpty, !token.isEmpty,
      [gt, challenge, token].allSatisfy({ $0.utf8.count <= 4096 })
    else { throw ServiceError("验证码信息不完整，请重试") }
    self.gt = gt; self.challenge = challenge; self.token = token; self.v4 = v4
  }
  static func isV4(_ type: String?) -> Bool { type == "geetest4" }
}
/// What the official web captcha controller submits: v3's challenge, validate and seccode, or
/// v4's lot number, output, pass token and time, each with the registration's recaptcha token.
struct MobileCaptchaSolution {
  enum Result {
    case v3(challenge: String, validate: String, seccode: String)
    case v4(lotNumber: String, output: String, passToken: String, time: String)
  }
  let result: Result, token: String
  /// The v3 challenge Geetest echoes back, which must belong to the registration shown.
  var challenge: String? {
    if case .v3(let challenge, _, _) = result { return challenge }
    return nil
  }
  var fields: [String: String] {
    switch result {
    case .v3(let challenge, let validate, let seccode):
      return ["gee_challenge": challenge, "gee_validate": validate, "gee_seccode": seccode, "recaptcha_token": token]
    case .v4(let lotNumber, let output, let passToken, let time):
      return ["gee_lot_number": lotNumber, "gee_captcha_output": output, "gee_pass_token": passToken,
        "gee_gen_time": time, "recaptcha_token": token]
    }
  }
}
struct MobileLoginSession {
  let cookies: [String: String], token: String, refresh: String?, device: String
  static func decode(_ data: [String: Any], device: String) throws -> Self {
    let tokens = data["token_info"] as? [String: Any] ?? data
    guard let token = tokens["access_token"] as? String, (8...1024).contains(token.utf8.count),
      token.utf8.allSatisfy({ (33...126).contains($0) }),
      let info = data["cookie_info"] as? [String: Any], let list = info["cookies"] as? [[String: Any]]
    else { throw ServiceError("未能取得完整登录信息，请重试") }
    let allowed: Set<String> = ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid", "buvid3", "buvid4"]
    var cookies: [String: String] = [:]
    for row in list {
      guard let name = row["name"] as? String, allowed.contains(name), let value = row["value"] as? String,
        !value.isEmpty, value.utf8.count <= 16_384, value.utf8.allSatisfy({ (33...126).contains($0) && $0 != 59 })
      else { continue }
      if let previous = cookies[name], previous != value { throw ServiceError("登录信息冲突，请重试") }
      cookies[name] = value
    }
    guard let uid = cookies["DedeUserID"], let number = Int64(uid), number > 0,
      cookies["SESSDATA"] != nil, cookies["bili_jct"] != nil
    else { throw ServiceError("未能取得完整登录信息，请重试") }
    if let mid = tokens["mid"] as? NSNumber, mid.int64Value > 0, mid.int64Value != number {
      throw ServiceError("登录信息与账号不匹配")
    }
    return .init(cookies: cookies, token: token, refresh: tokens["refresh_token"] as? String, device: device)
  }
}
struct MobileRiskContext {
  let url: URL, temporaryCode: String, requestID: String, source: String
  init(_ raw: String) throws {
    guard let url = URL(string: raw), url.scheme == "https", url.host == "passport.bilibili.com",
      url.user == nil, url.password == nil, url.port == nil,
      url.path.hasPrefix("/h5-app/passport/risk/"), let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { throw ServiceError("安全验证地址无效") }
    let groups = Dictionary(grouping: c.queryItems ?? [], by: \.name)
    func field(_ key: String) throws -> String {
      guard let values = groups[key], values.count == 1, let value = values[0].value,
        !value.isEmpty, value.utf8.count < 4096 else { throw ServiceError("安全验证信息不完整") }
      return value
    }
    self.url = url; temporaryCode = try field("tmp_token"); requestID = try field("request_id"); source = try field("source")
  }
}
enum MobileLoginOutcome {
  case session(MobileLoginSession), captcha(MobileCaptcha), risk(MobileRiskContext)
}
enum MobileQRPoll {
  case waiting, scanned, expired, session(MobileLoginSession)
}
enum MobileSMSSent {
  case sent(String), captcha(MobileCaptcha)
}

actor MobilePassport {
  typealias Transport = @Sendable (URLRequest) async throws -> Data
  private let send: Transport
  private let deviceID: String
  let buvid: String
  init(buvid: String = MobileDeviceID.guest(), deviceID: String = MobilePassport.newDeviceID(), transport: @escaping Transport = { try await MobilePassportNetwork.send($0) }) {
    self.buvid = buvid; self.deviceID = deviceID; send = transport
  }
  static func newDeviceID() -> String {
    let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
    func bcd(_ n: Int) -> UInt8 { UInt8((n / 10) * 16 + n % 10) }
    let year = c.year ?? 2026
    let bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
      + [bcd(year / 100), bcd(year % 100), bcd(c.month ?? 1), bcd(c.day ?? 1), bcd(c.hour ?? 0), bcd(c.minute ?? 0), bcd(c.second ?? 0)]
      + (0..<8).map { _ in UInt8.random(in: 0...255) }
    return bytes.map { String(format: "%02x", $0) }.joined() + String(format: "%02x", bytes.reduce(0) { $0 + Int($1) } & 255)
  }
  struct Packet {
    let code: Int, message: String, data: [String: Any]
    func requireSuccess() throws {
      guard code == 0 else { throw ServiceError(message.isEmpty ? "登录未完成（\(code)）" : message) }
    }
  }
  static func request(path: String, method: String = "POST", fields: [String: String] = [:], signed: Bool = true,
    query: Bool = false, buvid: String, referer: URL? = nil, timestamp: Int64 = Int64(Date().timeIntervalSince1970)) throws -> URLRequest
  {
    guard path.hasPrefix("/x/"), !path.contains("?"), !path.contains("#"),
      let url = URL(string: "https://passport.bilibili.com" + path) else { throw URLError(.badURL) }
    let values = signed ? MobileClientSigning.signed(fields, timestamp: timestamp) : fields
    let form = MobileClientSigning.formEncoded(values)
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    if query || method == "GET" { components.percentEncodedQuery = form.isEmpty ? nil : form }
    guard let target = components.url else { throw URLError(.badURL) }
    var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
    request.httpMethod = method; request.httpShouldHandleCookies = false
    if method == "POST", !query { request.httpBody = Data(form.utf8) }
    request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
    request.setValue(MobileClientSigning.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("android_hd", forHTTPHeaderField: "app-key")
    request.setValue("prod", forHTTPHeaderField: "env")
    request.setValue(buvid, forHTTPHeaderField: "buvid")
    if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
    return request
  }
  static func deviceListRequest(csrf: String, token: String, buvid: String, cookie: String,
    timestamp: Int64 = Int64(Date().timeIntervalSince1970)) throws -> URLRequest
  {
    var result = try request(path: "/x/safecenter/user_login_devices", method: "GET", fields: [
      "device_name": "iPhone", "device_platform": "iOS", "csrf": csrf, "mobi_app": "android_hd", "platform": "android",
      "access_key": token, "local_id": buvid, "buvid": buvid, "statistics": MobileClientSigning.statistics,
    ], buvid: buvid, referer: URL(string: "https://account.bilibili.com/"), timestamp: timestamp)
    result.setValue(cookie, forHTTPHeaderField: "Cookie")
    return result
  }
  private func packet(_ path: String, method: String = "POST", _ fields: [String: String] = [:], signed: Bool = true,
    query: Bool = false, referer: URL? = nil) async throws -> Packet
  {
    try Task.checkCancellation()
    let bytes = try await send(Self.request(path: path, method: method, fields: fields, signed: signed, query: query, buvid: buvid, referer: referer))
    try Task.checkCancellation()
    guard bytes.count <= 2 * 1024 * 1024,
      let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], let code = json["code"] as? Int
    else { throw ServiceError("登录服务返回异常，请重试") }
    return .init(code: code, message: json["message"] as? String ?? json["msg"] as? String ?? "", data: json["data"] as? [String: Any] ?? [:])
  }
  private var base: [String: String] {
    ["build": "2001100", "buvid": buvid, "c_locale": "zh_CN", "channel": "master", "disable_rcmd": "0",
      "local_id": buvid, "mobi_app": "android_hd", "platform": "android", "s_locale": "zh_CN", "statistics": MobileClientSigning.statistics]
  }
  private func loginBase(key: String, password: Bool) throws -> [String: String] {
    var fields = base
    fields.merge(["bili_local_id": deviceID, "device": "phone", "device_id": deviceID, "device_name": "iPhone",
      "device_platform": "iOS", "dt": MobileClientSigning.component(try MobilePasswordCipher.encrypt(String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)), pem: key)),
      "from_pv": password ? "main.homepage.avatar-nologin.all.click" : "main.my-information.my-login.0.click",
      "from_url": MobileClientSigning.component(password ? "bilibili://pegasus/promo" : "bilibili://user_center/mine")], uniquingKeysWith: { _, n in n })
    return fields
  }
  struct Ticket { let code: String, url: URL }
  func qrTicket() async throws -> Ticket {
    let result = try await packet("/x/passport-tv-login/qrcode/auth_code", ["local_id": "0", "platform": "android", "mobi_app": "android_hd"], query: true)
    try result.requireSuccess()
    guard let code = result.data["auth_code"] as? String, !code.isEmpty,
      let raw = result.data["url"] as? String, let url = URL(string: raw), url.scheme == "https",
      url.host == "passport.bilibili.com", url.user == nil, url.password == nil, url.port == nil
    else { throw ServiceError("登录二维码无效，请重试") }
    return .init(code: code, url: url)
  }
  func qrPoll(_ ticket: Ticket) async throws -> MobileQRPoll {
    let result = try await packet("/x/passport-tv-login/qrcode/poll", ["auth_code": ticket.code, "local_id": "0"], query: true)
    switch result.code {
    case 0: return .session(try .decode(result.data, device: buvid))
    case 86038: return .expired
    case 86090: return .scanned
    case 86039, 86101: return .waiting
    default: try result.requireSuccess(); throw ServiceError("登录未完成，请刷新二维码")
    }
  }
  private func publicKey() async throws -> (key: String, salt: String) {
    let result = try await packet("/x/passport-login/web/key", method: "GET", signed: false)
    try result.requireSuccess()
    guard let key = result.data["key"] as? String, let salt = result.data["hash"] as? String else {
      throw ServiceError("未取得登录加密密钥")
    }
    return (key, salt)
  }
  /// The registration is in the query of `recaptcha_url`, which points at the official H5 verify
  /// page (`www.bilibili.com/h5/project-msg-auth/verify?ct=…&gee_gt=…`); only the query is read and
  /// the page is never opened. A passport-only host check rejected that page, so login captchas
  /// fell back to a separate pre-registration whose token was not the one the request issued.
  static func captchaRegistration(_ data: [String: Any]) -> MobileCaptcha? {
    for field in ["recaptcha_url", "url"] {
      guard let raw = data[field] as? String, let url = URL(string: raw), url.scheme == "https",
        ["www.bilibili.com", "passport.bilibili.com"].contains(url.host ?? ""),
        url.user == nil, url.password == nil, url.port == nil,
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
      else { continue }
      let groups = Dictionary(grouping: c.queryItems ?? [], by: \.name)
      guard groups.values.allSatisfy({ $0.count == 1 }), let gt = groups["gee_gt"]?.first?.value,
        let token = groups["recaptcha_token"]?.first?.value
      else { continue }
      let type = groups["ct"]?.first?.value ?? groups["recaptcha_type"]?.first?.value ?? data["recaptcha_type"] as? String
      if let result = try? MobileCaptcha(gt: gt, challenge: groups["gee_challenge"]?.first?.value ?? "", token: token,
        v4: MobileCaptcha.isV4(type)) { return result }
    }
    return nil
  }
  private func captcha(_ data: [String: Any]) async throws -> MobileCaptcha {
    if let result = Self.captchaRegistration(data) { return result }
    return try await preCaptcha()
  }
  func preCaptcha() async throws -> MobileCaptcha {
    let result = try await packet("/x/safecenter/captcha/pre", signed: false)
    try result.requireSuccess()
    return try MobileCaptcha(gt: result.data["gee_gt"] as? String ?? "", challenge: result.data["gee_challenge"] as? String ?? "",
      token: result.data["recaptcha_token"] as? String ?? "", v4: MobileCaptcha.isV4(result.data["recaptcha_type"] as? String))
  }
  private func outcome(_ result: Packet) async throws -> MobileLoginOutcome {
    if result.code == -105 { return .captcha(try await captcha(result.data)) }
    try result.requireSuccess()
    if result.data["status"] as? Int == 2, let raw = result.data["url"] as? String {
      return .risk(try MobileRiskContext(raw))
    }
    return .session(try .decode(result.data, device: buvid))
  }
  func password(username: String, password: String, captcha: MobileCaptchaSolution? = nil) async throws -> MobileLoginOutcome {
    guard !username.isEmpty, !password.isEmpty, username.utf8.count <= 512, password.utf8.count <= 4096 else { throw ServiceError("请填写账号和密码") }
    let key = try await publicKey()
    var fields = try loginBase(key: key.key, password: true)
    fields["username"] = username; fields["password"] = try MobilePasswordCipher.encrypt(key.salt + password, pem: key.key); fields["permission"] = "ALL"
    if let captcha { fields.merge(captcha.fields, uniquingKeysWith: { _, n in n }) }
    return try await outcome(packet("/x/passport-login/oauth2/login", fields))
  }
  func sendSMS(phone: String, country: Int, captcha: MobileCaptchaSolution? = nil) async throws -> MobileSMSSent {
    try Self.validatePhone(phone, country)
    var fields = base
    fields["cid"] = String(country); fields["tel"] = phone
    fields["login_session_id"] = MobileClientSigning.digest(buvid + String(Int64(Date().timeIntervalSince1970 * 1000)))
    if let captcha { fields.merge(captcha.fields, uniquingKeysWith: { _, n in n }) }
    let result = try await packet("/x/passport-login/sms/send", fields)
    if result.code == -105 || (result.code == 0 && (result.data["recaptcha_url"] as? String)?.isEmpty == false) {
      return .captcha(try await self.captcha(result.data))
    }
    try result.requireSuccess()
    guard let key = result.data["captcha_key"] as? String, !key.isEmpty else { throw ServiceError("未取得短信验证码信息，请重试") }
    return .sent(key)
  }
  func sms(phone: String, country: Int, code: String, captchaKey: String, captcha: MobileCaptchaSolution? = nil) async throws -> MobileLoginOutcome {
    try Self.validatePhone(phone, country); try Self.validateCode(code)
    guard !captchaKey.isEmpty else { throw ServiceError("请先获取验证码") }
    let key = try await publicKey()
    var fields = try loginBase(key: key.key, password: false)
    fields.merge(["cid": String(country), "tel": phone, "code": code, "captcha_key": captchaKey], uniquingKeysWith: { _, n in n })
    if let captcha { fields.merge(captcha.fields, uniquingKeysWith: { _, n in n }) }
    return try await outcome(packet("/x/passport-login/login/sms", fields))
  }
  static func validatePhone(_ phone: String, _ country: Int) throws {
    guard (3...32).contains(phone.count), phone.utf8.allSatisfy({ (48...57).contains($0) }), country > 0 else { throw ServiceError("请输入正确的手机号") }
  }
  static func validateCode(_ code: String) throws {
    guard (4...10).contains(code.count), code.utf8.allSatisfy({ (48...57).contains($0) }) else { throw ServiceError("请输入短信验证码") }
  }
  func riskInfo(_ risk: MobileRiskContext) async throws -> String {
    let result = try await packet("/x/safecenter/user/info", method: "GET", ["tmp_code": risk.temporaryCode], signed: false)
    try result.requireSuccess()
    guard let info = result.data["account_info"] as? [String: Any], info["tel_verify"] as? Bool == true else {
      throw ServiceError("此账号暂无法使用手机号验证，请选择其他登录方式")
    }
    return info["hide_tel"] as? String ?? "已绑定的手机号"
  }
  func sendRiskSMS(_ risk: MobileRiskContext, captcha: MobileCaptchaSolution) async throws -> String {
    var fields = ["disable_rcmd": "0", "sms_type": "loginTelCheck", "tmp_code": risk.temporaryCode]
    fields.merge(captcha.fields, uniquingKeysWith: { _, n in n })
    let result = try await packet("/x/safecenter/common/sms/send", fields, referer: risk.url)
    try result.requireSuccess()
    guard let key = result.data["captcha_key"] as? String, !key.isEmpty else { throw ServiceError("未取得短信验证码信息，请重试") }
    return key
  }
  func verifyRisk(_ risk: MobileRiskContext, code: String, captchaKey: String) async throws -> MobileLoginSession {
    try Self.validateCode(code)
    guard !captchaKey.isEmpty else { throw ServiceError("请先获取验证码") }
    let result = try await packet("/x/safecenter/login/tel/verify", ["type": "loginTelCheck", "code": code,
      "tmp_code": risk.temporaryCode, "request_id": risk.requestID, "source": risk.source, "captcha_key": captchaKey], referer: risk.url)
    try result.requireSuccess()
    guard let oauth = result.data["code"] as? String, !oauth.isEmpty else { throw ServiceError("安全验证未完成，请重试") }
    let exchanged = try await packet("/x/passport-login/oauth2/access_token", ["build": "2001100", "buvid": buvid,
      "code": oauth, "disable_rcmd": "0", "grant_type": "authorization_code", "local_id": buvid, "mobi_app": "android_hd", "platform": "android"])
    try exchanged.requireSuccess()
    return try .decode(exchanged.data, device: buvid)
  }
}

enum MobilePassportNetwork {
  static func send(_ request: URLRequest) async throws -> Data {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
    let proxy = APIProxy.current(); proxy.apply(to: config)
    let native = URLSession(configuration: config, delegate: APIRedirectPolicy(), delegateQueue: nil)
    defer { native.finishTasksAndInvalidate() }
    let bytes: Data, raw: URLResponse
    do { (bytes, raw) = try await BiliServiceSession(native: native, proxy: proxy).data(for: request) }
    catch { try Task.checkCancellation(); throw ServiceError("暂时无法连接登录服务") }
    try Task.checkCancellation()
    guard (raw as? HTTPURLResponse)?.statusCode == 200 else { throw ServiceError("登录服务暂时不可用") }
    return bytes
  }
}

enum MobileLoginVerifier {
  struct Verified {
    let cookies: [String: String], token: String, refresh: String?, device: String, name: String
  }
  static func verify(_ session: MobileLoginSession, expectedUID: String?,
    web: @escaping @Sendable ([String: String]) async throws -> (cookies: [String: String], name: String) = { try await WebLoginIdentity.verify($0) },
    mobile: @escaping @Sendable (String) async throws -> Int64 = { try await ImportedCredentialProbe.mobileOwner($0) }) async throws -> Verified
  {
    async let cookie = web(session.cookies)
    async let owner = mobile(session.token)
    let (login, mid) = try await (cookie, owner)
    try Task.checkCancellation()
    guard let uid = login.cookies["DedeUserID"], uid == String(mid), session.cookies["DedeUserID"] == uid,
      expectedUID == nil || expectedUID == uid else { throw ServiceError("请使用当前账号完成授权") }
    return .init(cookies: login.cookies, token: session.token, refresh: session.refresh, device: session.device, name: login.name)
  }
}
