import SwiftUI

enum NativeLoginMethod: String, CaseIterable, Identifiable {
  case qr = "扫码", password = "密码", sms = "短信"
  var id: Self { self }
}

@MainActor final class NativeLoginFlow: ObservableObject {
  @Published private(set) var busy = false
  @Published private(set) var issue: String?
  @Published private(set) var ticket: MobilePassport.Ticket?
  @Published private(set) var expiry: Date?
  @Published private(set) var status = "使用哔哩哔哩客户端扫码"
  @Published private(set) var completedUID: String?
  @Published var captcha: MobileCaptcha?
  @Published private(set) var risk: MobileRiskContext?
  @Published private(set) var maskedPhone = ""
  @Published private(set) var cooldown: Date?
  private let api: MobilePassport
  private let expectedUID: String?
  private var active = false
  private var operation = UUID()
  private var work: Task<Void, Never>?
  private enum Pending {
    case password(String, String), smsSend(String, Int), smsLogin(String, Int, String, String), riskSend(MobileRiskContext)
  }
  private var pending: Pending?
  private var smsInfo: (phone: String, country: Int, key: String, until: Date)?
  private var riskSMS: (key: String, until: Date)?
  init(expectedUID: String?, api: MobilePassport = MobilePassport()) { self.expectedUID = expectedUID; self.api = api }
  func activate() { active = true }
  func cancel() {
    active = false; operation = UUID(); work?.cancel(); work = nil; pending = nil
    captcha = nil; ticket = nil; expiry = nil; risk = nil; smsInfo = nil; riskSMS = nil; busy = false
  }
  private func check(_ id: UUID) throws {
    try Task.checkCancellation()
    guard active, operation == id else { throw CancellationError() }
  }
  private func perform(_ action: @escaping (UUID, UInt64) async throws -> Void) {
    guard active else { return }
    work?.cancel(); let id = UUID(); operation = id; busy = true; issue = nil
    work = Task {
      defer { if operation == id { busy = false; work = nil } }
      do {
        let stamp = try await AccountJar.shared.packStamp()
        try check(id)
        if let expectedUID, stamp.active != expectedUID { throw ServiceError("账号已切换") }
        try await action(id, stamp.generation)
      } catch { if active, operation == id, !Task.isCancelled { issue = error.localizedDescription } }
    }
  }
  private func save(_ session: MobileLoginSession, id: UUID, generation: UInt64) async throws {
    let result = try await MobileLoginVerifier.verify(session, expectedUID: expectedUID)
    try check(id)
    try await AccountJar.shared.addSession(result.cookies, token: result.token, refresh: result.refresh,
      device: result.device, label: result.name, expectedGeneration: generation)
    try check(id)
    pending = nil; captcha = nil; risk = nil; ticket = nil; expiry = nil
    completedUID = result.cookies["DedeUserID"]
  }
  private func handle(_ outcome: MobileLoginOutcome, retry: Pending, id: UUID, generation: UInt64) async throws {
    try check(id)
    switch outcome {
    case .session(let session): try await save(session, id: id, generation: generation)
    case .captcha(let challenge): pending = retry; captcha = challenge
    case .risk(let context):
      let masked = try await api.riskInfo(context)
      try check(id); risk = context; maskedPhone = masked; riskSMS = nil; cooldown = nil
    }
  }
  func startQR() {
    ticket = nil; expiry = nil; status = "正在获取二维码"
    perform { [self] id, generation in
      let value = try await api.qrTicket()
      try check(id)
      ticket = value; let until = Date().addingTimeInterval(180); expiry = until; busy = false
      status = "使用哔哩哔哩客户端扫码"
      while Date() < until {
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let result = try await api.qrPoll(value)
        try check(id)
        switch result {
        case .waiting: break
        case .scanned: status = "已扫码，请在哔哩哔哩客户端确认"
        case .expired: expiry = nil; status = "二维码已过期"; return
        case .session(let session): try await save(session, id: id, generation: generation); return
        }
      }
      try check(id); expiry = nil; status = "二维码已过期"
    }
  }
  func password(_ username: String, _ password: String, solution: MobileCaptchaSolution? = nil) {
    perform { [self] id, generation in
      let result = try await api.password(username: username, password: password, captcha: solution)
      try await handle(result, retry: .password(username, password), id: id, generation: generation)
    }
  }
  func sendSMS(_ phone: String, _ country: Int, solution: MobileCaptchaSolution? = nil) {
    guard cooldown.map({ $0 <= Date() }) ?? true else { return }
    perform { [self] id, _ in
      let result = try await api.sendSMS(phone: phone, country: country, captcha: solution)
      try check(id)
      switch result {
      case .captcha(let value): pending = .smsSend(phone, country); captcha = value
      case .sent(let key):
        smsInfo = (phone, country, key, Date().addingTimeInterval(300)); cooldown = Date().addingTimeInterval(60)
        issue = "验证码已发送"
      }
    }
  }
  func sms(_ phone: String, _ country: Int, _ code: String, solution: MobileCaptchaSolution? = nil) {
    guard let info = smsInfo, info.phone == phone, info.country == country else { issue = "请先获取验证码"; return }
    guard Date() < info.until else { issue = "验证码已过期，请重新获取"; return }
    perform { [self] id, generation in
      let result = try await api.sms(phone: phone, country: country, code: code, captchaKey: info.key, captcha: solution)
      try await handle(result, retry: .smsLogin(phone, country, code, info.key), id: id, generation: generation)
    }
  }
  func changedPhone() {
    work?.cancel(); operation = UUID(); work = nil; pending = nil; captcha = nil; smsInfo = nil; cooldown = nil; busy = false; issue = nil
  }
  func sendRiskSMS() {
    guard let context = risk, cooldown.map({ $0 <= Date() }) ?? true else { return }
    perform { [self] id, _ in
      let challenge = try await api.preCaptcha()
      try check(id); pending = .riskSend(context); captcha = challenge
    }
  }
  func verifyRisk(_ code: String) {
    guard let context = risk, let info = riskSMS else { issue = "请先获取验证码"; return }
    guard Date() < info.until else { issue = "验证码已过期，请重新获取"; return }
    perform { [self] id, generation in
      try await save(api.verifyRisk(context, code: code, captchaKey: info.key), id: id, generation: generation)
    }
  }
  func solved(_ solution: MobileCaptchaSolution, challengeID: UUID) {
    guard active, let challenge = captcha, challenge.id == challengeID, challenge.token == solution.token,
      // A v4 result carries no challenge; the page already matched its captcha id to `gt`.
      solution.challenge.map({ $0.hasPrefix(String(challenge.challenge.prefix(32))) }) ?? true,
      let retry = pending else { return }
    pending = nil; captcha = nil
    switch retry {
    case .password(let user, let password): self.password(user, password, solution: solution)
    case .smsSend(let phone, let country): sendSMS(phone, country, solution: solution)
    case .smsLogin(let phone, let country, let code, _): sms(phone, country, code, solution: solution)
    case .riskSend(let context):
      perform { [self] id, _ in
        let key = try await api.sendRiskSMS(context, captcha: solution)
        try check(id); riskSMS = (key, Date().addingTimeInterval(300)); cooldown = Date().addingTimeInterval(60); issue = "验证码已发送"
      }
    }
  }
  func closedCaptcha() { if captcha == nil { pending = nil } }
  func leaveRisk() { risk = nil; riskSMS = nil; cooldown = nil; issue = nil }
}
