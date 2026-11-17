import Foundation
import PiliArchive
import Security
import SwiftUI

struct Identity: Codable, Identifiable {
  var id: String
  var label: String
  fileprivate var cookies: [String: String]
  var responseCookies: [WebCookieValue]? = nil
  var mobileToken: String? = nil
  var credentialProof: ImportedCredentialProof? = nil
  var archiveRefresh: String? = nil, archiveDevice: String? = nil, archiveRoles: [Int]? = nil
  var header: String {
    WebCookieJar.header(WebCookieJar.root(cookies, responseCookies ?? []))
  }
  var csrf: String? { WebCookieJar.root(cookies, responseCookies ?? [])["bili_jct"] }
  var siteDeviceID: String? { WebCookieJar.root(cookies, responseCookies ?? [])["buvid3"] }
  var webCookies: [HTTPCookie] {
    WebCookieJar.all(cookies, responseCookies ?? []).compactMap { row in
      let k = row.name
      guard
        ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid", "buvid3", "buvid4"]
          .contains(k)
      else { return nil }
      guard row.expires.map({ $0 > Date() }) ?? true else { return nil }
      return row.cookie
    }
  }
}

actor AccountJar {
  static let shared = AccountJar()
  struct State: Codable {
    var accounts: [Identity] = []
    var active: String?
    var routes: AccountRoutes?
    var guestCookies: [String: String]? = nil
    var guestResponseCookies: [WebCookieValue]? = nil
    var effectiveRoutes: AccountRoutes {
      if let routes { return routes }
      var r = AccountRoutes()
      if accounts.contains(where: { $0.archiveRoles != nil }) {
        for role in AccountRole.allCases where role != .main {
          r.set(
            role,
            choice: accounts.first(where: { $0.archiveRoles?.contains(role.rawValue) == true })?.id
              ?? AccountRoutes.guest)
        }
      }
      return r
    }
    func owner(_ use: AccountUse) -> String? {
      effectiveRoutes.owner(use, main: active, available: Set(accounts.map(\.id)))
    }
  }
  private var temporaryPrivateOwner: String?
  private var cached: State?
  private let fields: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "PiliNative.Accounts",
    kSecAttrAccount as String: "sessions",
  ]
  func state() throws -> State {
    if let cached { return cached }
    var q = fields
    q[kSecReturnData as String] = true
    var item: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &item)
    if status == errSecItemNotFound { let empty = State(); cached = empty; return empty }
    guard status == errSecSuccess, let bytes = item as? Data else { throw ServiceError("无法读取钥匙串") }
    let s = try JSONDecoder().decode(State.self, from: bytes)
    cached = s
    return s
  }
  private func persist(_ s: State) throws {
    let done = try SleepExitFence.shared.enter(); defer { done() }
    let bytes = try JSONEncoder().encode(s)
    let attr = [kSecValueData as String: bytes] as CFDictionary
    var status = SecItemUpdate(fields as CFDictionary, attr)
    if status == errSecItemNotFound {
      var q = fields
      q[kSecValueData as String] = bytes
      q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      status = SecItemAdd(q as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw ServiceError("无法保存账号") }
    cached = s
    packGeneration &+= 1
    if temporaryPrivateOwner != s.active { temporaryPrivateOwner = nil }
  }
  func presentedState() throws -> State {
    var s = try state()
    if let owner = temporaryPrivateOwner, s.active == owner { s.routes = s.effectiveRoutes.privatePlaybackCopy() }
    return s
  }
  func privatePlayback(_ enabled: Bool, permanent: Bool, owner: String) throws {
    guard try state().active == owner else { throw ServiceError("账号已切换") }
    if enabled && !permanent { temporaryPrivateOwner = owner }
    else { try assign(.heartbeat, choice: enabled ? AccountRoutes.guest : AccountRoutes.follow) }
  }
  func current(_ use: AccountUse = .role(.main), credentials: AccountCredentials = .web) async throws -> Identity? {
    let s = try presentedState()
    let id = s.owner(use)
    guard let candidate = s.accounts.first(where: { $0.id == id }) else { return nil }
    let verified = try await validateImported(candidate, credentials:credentials)
    guard try presentedState().owner(use) == id else { throw ServiceError("账号已切换") }
    return verified
  }
  func webSession(_ use: AccountUse = .role(.main)) async throws -> WebSessionSnapshot {
    let identity = try await current(use)
    try Task.checkCancellation()
    guard try presentedState().owner(use) == identity?.id else { throw ServiceError("账号已切换") }
    return try webSnapshot(owner: identity?.id)
  }
  func bindWeb(_ identity: Identity, use: AccountUse = .role(.main)) throws -> WebSessionSnapshot {
    guard try presentedState().owner(use) == identity.id else { throw ServiceError("账号已切换") }
    let bound = try webSnapshot(owner: identity.id)
    guard WebCookieJar.core.allSatisfy({ identity.cookies[$0] == bound.legacyCookies[$0] }),
      identity.mobileToken == nil || identity.mobileToken == bound.token else { throw ServiceError("账号授权已变更") }
    return bound
  }
  func webSnapshot(owner: String?) throws -> WebSessionSnapshot {
    try snapshot(owner: owner, initializeVisitor: true)
  }
  private func snapshot(owner: String?, initializeVisitor: Bool) throws -> WebSessionSnapshot {
    var s = try state()
    let legacy: [String: String], stored: [WebCookieValue], token: String?, device: String
    if let owner {
      guard let i = s.accounts.firstIndex(where: { $0.id == owner }) else { throw ServiceError("账号已切换") }
      if initializeVisitor, s.accounts[i].cookies["buvid3"] == nil {
        s.accounts[i].cookies["buvid3"] = WebCookieJar.newBuvid3(); try persist(s)
      }
      legacy = s.accounts[i].cookies; stored = s.accounts[i].responseCookies ?? []
      token = s.accounts[i].mobileToken; device = MobileDeviceID.use(s.accounts[i].archiveDevice)
    } else {
      if initializeVisitor, s.guestCookies?["buvid3"] == nil {
        s.guestCookies = (s.guestCookies ?? [:]).merging(["buvid3": WebCookieJar.newBuvid3()]) { _, v in v }; try persist(s)
      }
      legacy = s.guestCookies ?? [:]; stored = s.guestResponseCookies ?? []; token = nil; device = MobileDeviceID.guest()
    }
    let presented = try presentedState()
    return .init(owner: owner, legacyCookies: legacy, storedCookies: stored, token: token, device: device,
      active: presented.active, routes: presented.effectiveRoutes)
  }
  func mergeResponseCookies(_ cookies: [HTTPCookie], from url: URL, bound: WebSessionSnapshot, use: AccountUse? = nil, verifiedOwner: String? = nil) async throws -> WebSessionSnapshot? {
    try Task.checkCancellation()
    guard WebCookieJar.webURL(url), (try? snapshot(owner: bound.owner, initializeVisitor: false))?.sameIdentity(as: bound) == true,
      try use.map({ try presentedState().owner($0) == bound.owner }) ?? true else { return nil }
    var current = try snapshot(owner: bound.owner, initializeVisitor: false)
    var update = try WebCookieJar.update(legacy: current.legacyCookies, stored: current.storedCookies, cookies: cookies, from: url, owner: bound.owner)
    var verifiedCookies = [HTTPCookie]()
    if update.verifyIdentity, let owner = bound.owner, verifiedOwner != owner {
      let identity = try await WebLoginIdentity.inspect(WebCookieJar.root(update.legacy, update.stored))
      try ImportedCredentialProof.require(identity.cookies["DedeUserID"] ?? "", owner: owner)
      verifiedCookies = identity.responseCookies
    }
    try Task.checkCancellation()
    guard (try? snapshot(owner: bound.owner, initializeVisitor: false))?.sameIdentity(as: bound) == true,
      try use.map({ try presentedState().owner($0) == bound.owner }) ?? true else { return nil }
    current = try snapshot(owner: bound.owner, initializeVisitor: false)
    // Auxiliary cookie responses can complete concurrently; merge against the latest jar.
    update = try WebCookieJar.update(legacy: current.legacyCookies, stored: current.storedCookies, cookies: cookies, from: url, owner: bound.owner)
    if !verifiedCookies.isEmpty {
      update = try WebCookieJar.update(legacy: update.legacy, stored: update.stored, cookies: verifiedCookies,
        from: URL(string: "https://api.bilibili.com/x/web-interface/nav")!, owner: bound.owner)
    }
    guard update.legacy != current.legacyCookies || update.stored != current.storedCookies else { return current }
    var s = try state()
    if let owner = bound.owner, let i = s.accounts.firstIndex(where: { $0.id == owner }) {
      s.accounts[i].cookies = update.legacy; s.accounts[i].responseCookies = update.stored
    } else {
      s.guestCookies = update.legacy; s.guestResponseCookies = update.stored
    }
    try persist(s)
    return try webSnapshot(owner: bound.owner)
  }
  func webMatches(_ bound: WebSessionSnapshot, use: AccountUse? = nil) throws -> Bool {
    guard let current = try? snapshot(owner: bound.owner, initializeVisitor: false), current.sameIdentity(as: bound) else { return false }
    return try use.map { try presentedState().owner($0) == bound.owner } ?? true
  }
  func revokeInvalidMain(_ bound: WebSessionSnapshot, cookies: [HTTPCookie] = [], from url: URL? = nil) throws -> Bool {
    try Task.checkCancellation()
    guard let owner = bound.owner, try state().active == owner,
      (try? snapshot(owner: owner, initializeVisitor: false))?.sameIdentity(as: bound) == true else { return false }
    var s = try state(); var routes = s.effectiveRoutes
    // Apply valid response cookies to this bound account before its confirmed logout, in one
    // transaction. No other request can observe an intermediate, newly issued credential.
    if let url, let i = s.accounts.firstIndex(where: { $0.id == owner }),
      let update = try? WebCookieJar.update(legacy: s.accounts[i].cookies, stored: s.accounts[i].responseCookies ?? [], cookies: cookies, from: url, owner: owner) {
      s.accounts[i].cookies = update.legacy; s.accounts[i].responseCookies = update.stored
    }
    routes.remove(owner); s.routes = routes; s.active = nil
    s.accounts.removeAll { $0.id == owner }
    try persist(s)
    return true
  }
  private func inspectSelectedMain() async {
    guard let selected = try? state(), let owner = selected.active,
      let bound = try? snapshot(owner: owner, initializeVisitor: false) else { return }
    do {
      let result = try await WebLoginIdentity.inspect(bound.cookies)
      try Task.checkCancellation()
      try ImportedCredentialProof.require(result.cookies["DedeUserID"] ?? "", owner: owner)
      guard try webMatches(bound, use: .role(.main)) else { return }
      guard let updated = try await mergeResponseCookies(result.responseCookies,
        from: URL(string: "https://api.bilibili.com/x/web-interface/nav")!, bound: bound, use: .role(.main), verifiedOwner: owner),
        try webMatches(updated, use: .role(.main)) else { return }
      var s = try state()
      if let i = s.accounts.firstIndex(where: { $0.id == owner }), s.accounts[i].credentialProof?.web == false {
        s.accounts[i].credentialProof?.web = true; s.accounts[i].credentialProof?.ownerConfirmed = true; try persist(s)
      }
    } catch let error as ServiceError where error.code == -101 {
      if (try? revokeInvalidMain(bound)) == true { await InvalidWebSession.announce(owner) }
    } catch { /* An offline or challenged session remains available for a later check. */ }
  }
  /// Local cache identity is a previous device-confirmed principal, not a fresh imported UID claim.
  /// It never sends a request or returns any session credentials.
  func localOwner(_ use:AccountUse = .role(.main)) throws -> String? {
    let state=try presentedState()
    guard let id=state.owner(use),let candidate=state.accounts.first(where:{$0.id==id}) else{return nil}
    guard candidate.credentialProof?.permitsLocal(hasMobile:candidate.mobileToken?.isEmpty==false) ?? true
    else{throw ServiceError("请先联网确认导入的账号")}
    return id
  }
  func validateImported(_ candidate: Identity, credentials:AccountCredentials = .web) async throws -> Identity {
    func matching(_ state: State) -> Identity? {
      state.accounts.first { $0.id == candidate.id && $0.header == candidate.header && $0.mobileToken == candidate.mobileToken }
    }
    guard let existing = matching(try state()) else { throw ServiceError("登录信息已变更") }
    guard var proof = existing.credentialProof else { return existing }
    var verifiedOwner=proof.permitsLocal(hasMobile:existing.mobileToken?.isEmpty==false)
    if credentials != .mobile, !proof.web {
      let cookies = candidate.cookies
      let bound = try snapshot(owner: candidate.id, initializeVisitor: false)
      do {
        try await ImportedCredentialChecks.shared.validate(.init(owner:candidate.id,web:true,material:candidate.header)) {
          let result = try await WebLoginIdentity.verify(cookies)
          return result.cookies["DedeUserID"] ?? ""
        }
      } catch let error as ServiceError where error.code == -101 {
        if try revokeInvalidMain(bound) { await InvalidWebSession.announce(candidate.id) }
        throw error
      }
      proof.web=true;verifiedOwner=true
    }
    if credentials != .web, !proof.mobile, let token = candidate.mobileToken, !token.isEmpty {
      try await ImportedCredentialChecks.shared.validate(.init(owner:candidate.id,web:false,material:token)) {
        String(try await ImportedCredentialProbe.mobileOwner(token))
      }
      proof.mobile=true;verifiedOwner=true
    }
    var next = try state()
    guard matching(next) != nil, let i = next.accounts.firstIndex(where: { $0.id == candidate.id }) else {
      throw ServiceError("登录信息已变更")
    }
    // Another concurrent first-use may have proved the other capability while this one waited.
    if let latest=next.accounts[i].credentialProof {
      proof.web = proof.web || latest.web;proof.mobile = proof.mobile || latest.mobile
      verifiedOwner = verifiedOwner || latest.permitsLocal(hasMobile:next.accounts[i].mobileToken?.isEmpty==false)
    }
    proof.ownerConfirmed=verifiedOwner
    if next.accounts[i].credentialProof != proof {
      next.accounts[i].credentialProof=proof;try persist(next)
    }
    var result=next.accounts[i]
    if !proof.mobile { result.mobileToken=nil }
    if !proof.web { result.cookies=[:] }
    return result
  }
  func assign(_ role: AccountRole, choice: String) throws {
    var s = try state()
    var r = s.effectiveRoutes
    guard role != .main,
      choice == AccountRoutes.follow || choice == AccountRoutes.guest
        || s.accounts.contains(where: { $0.id == choice })
    else { throw ServiceError("账号不可用") }
    r.set(role, choice: choice)
    s.routes = r
    try persist(s)
    if role == .heartbeat { temporaryPrivateOwner = nil }
  }
  func add(_ cookies: [String: String], label: String, expectedGeneration: UInt64? = nil) throws {
    try Task.checkCancellation()
    if let expectedGeneration, expectedGeneration != packGeneration { throw ServiceError("账号已变更，请重新登录") }
    guard let uid = cookies["DedeUserID"], !uid.isEmpty, uid.allSatisfy(\.isNumber),
      cookies["SESSDATA"]?.isEmpty == false, cookies["bili_jct"]?.isEmpty == false
    else { throw ServiceError("授权未返回完整登录信息") }
    var s = try state()
    let previous = s.accounts.first { $0.id == uid }
    s.accounts.removeAll { $0.id == uid }
    s.accounts.append(
      Identity(
        id: uid, label: label.isEmpty ? "UID \(uid)" : label, cookies: cookies,
        mobileToken: previous?.mobileToken, archiveRefresh: previous?.archiveRefresh,
        archiveDevice: previous?.archiveDevice ?? MobileDeviceID.guest(), archiveRoles: previous?.archiveRoles))
    s.accounts[s.accounts.count - 1].credentialProof = .init(web:true,mobile:previous?.credentialProof?.mobile ?? true,ownerConfirmed:true)
    s.active = uid
    try persist(s)
  }
  /// The login exchange has already checked that both credentials resolve to the same UID.
  func addSession(_ cookies: [String: String], token: String, refresh: String?, device: String?, label: String, expectedGeneration: UInt64? = nil) throws {
    try Task.checkCancellation()
    if let expectedGeneration, expectedGeneration != packGeneration { throw ServiceError("账号已变更，请重新登录") }
    guard let uid = cookies["DedeUserID"], !uid.isEmpty, uid.allSatisfy(\.isNumber),
      cookies["SESSDATA"]?.isEmpty == false, cookies["bili_jct"]?.isEmpty == false,
      !token.isEmpty, device.map(MobileDeviceID.valid) ?? true
    else { throw ServiceError("授权未返回完整登录信息") }
    var s = try state()
    let previous = s.accounts.first { $0.id == uid }
    let session = Identity(
      id: uid, label: label.isEmpty ? previous?.label ?? "UID \(uid)" : label, cookies: cookies,
      mobileToken: token, credentialProof: .init(web: true, mobile: true, ownerConfirmed: true),
      archiveRefresh: refresh, archiveDevice: device ?? previous?.archiveDevice ?? MobileDeviceID.guest(),
      archiveRoles: previous?.archiveRoles)
    if let index = s.accounts.firstIndex(where: { $0.id == uid }) { s.accounts[index] = session }
    else { s.accounts.append(session) }
    s.active = uid
    try persist(s)
  }
  func updateDevices(guest: String, accounts values: [String: String]) throws {
    guard MobileDeviceID.valid(guest), values.values.allSatisfy(MobileDeviceID.valid) else {
      throw ServiceError("设备标识仅限字母、数字、短横线和下划线")
    }
    var s = try state()
    guard Set(s.accounts.map(\.id)) == Set(values.keys) else { throw ServiceError("账号列表已变更，请重新打开") }
    for i in s.accounts.indices { s.accounts[i].archiveDevice = values[s.accounts[i].id] }
    try persist(s)
    UserDefaults.standard.set(guest, forKey: MobileDeviceID.guestKey)
  }
  func setMobileToken(_ token: String?, for uid: String, expectedGeneration: UInt64? = nil) throws {
    try Task.checkCancellation()
    if let expectedGeneration, expectedGeneration != packGeneration { throw ServiceError("账号授权已变更，请重试") }
    var s = try state()
    guard s.active == uid, let i = s.accounts.firstIndex(where: { $0.id == uid }) else {
      throw ServiceError("账号已切换")
    }
    s.accounts[i].mobileToken = token
    if s.accounts[i].credentialProof != nil {
      s.accounts[i].credentialProof?.mobile = true
      if token?.isEmpty == false {s.accounts[i].credentialProof?.ownerConfirmed=true}
    }
    try persist(s)
  }
  func archiveData() throws -> Data {
    let s = try state()
    var values: [String: ArchiveAccount] = [:]
    for a in s.accounts {
      let roles = AccountRole.allCases.filter { s.owner(.role($0)) == a.id }.map(\.rawValue)
      values[a.id] = ArchiveAccount(
        cookies: a.cookies, accessKey: a.mobileToken, refresh: a.archiveRefresh,
        buvid: a.archiveDevice, type: roles, label: a.label)
    }
    return try JSONEncoder().encode(values)
  }
  func packRoleChoices() throws -> [String: String] {
    let s = try state()
    return Dictionary(uniqueKeysWithValues: AccountRole.allCases.map { role in
      (String(role.rawValue), role == .main ? s.active ?? "" : s.effectiveRoutes.choice(role))
    })
  }
  private var packGeneration: UInt64 = 0
  func packStamp() throws -> (generation: UInt64, active: String?, ids: Set<String>) {
    let s = try state()
    return (packGeneration, s.active, Set(s.accounts.map(\.id)))
  }
  func mergeArchive(_ values: [String: ArchiveAccount], choices: [String: String]? = nil, expectedGeneration: UInt64? = nil) async throws {
    if let expectedGeneration, expectedGeneration != packGeneration { throw ServiceError("账号已变更，请重新预览") }
    try ArchiveAccount.validateRoles(choices, accounts: values)
    guard !values.isEmpty || choices != nil else { return }
    var s = try state()
    let assigned = Set(values.values.flatMap { $0.type ?? [] })
    var routes = s.effectiveRoutes
    for role in AccountRole.allCases where role != .main {
      if let id = values.first(where: { $0.value.type?.contains(role.rawValue) == true })?.key {
        routes.set(role, choice: id)
      } else if let previous = s.owner(.role(role)), values[previous] == nil {
        routes.set(role, choice: previous)
      } else {
        routes.set(role, choice: AccountRoutes.guest)
      }
    }
    s.routes = routes
    for i in s.accounts.indices where values[s.accounts[i].id] == nil {
      s.accounts[i].archiveRoles = s.accounts[i].archiveRoles?.filter { !assigned.contains($0) }
    }
    for id in values.keys.sorted() {
      let a = values[id]!
      let previous = s.accounts.first { $0.id == id }
      let label =
        a.piliNativeLabel ?? s.accounts.first(where: { $0.id == id })?.label ?? "UID " + id
      s.accounts.removeAll { $0.id == id }
      s.accounts.append(
        .init(
          id: id, label: label, cookies: a.cookies, mobileToken: a.accessKey,
          archiveRefresh: a.refresh, archiveDevice: a.buvid, archiveRoles: a.type))
      s.accounts[s.accounts.count - 1].credentialProof = .restored(
        previous: previous?.credentialProof,
        sameWeb: previous?.cookies == a.cookies,
        sameMobile: a.accessKey == nil || (previous != nil && previous?.mobileToken == a.accessKey),
        knownOwner:previous.map{$0.credentialProof?.permitsLocal(hasMobile:$0.mobileToken?.isEmpty==false) ?? true} ?? false)
      if a.type?.contains(0) == true { s.active = id }
    }
    if let choices {
      s.active = choices["0"].flatMap { $0.isEmpty ? nil : $0 }
      for role in AccountRole.allCases where role != .main { routes.set(role, choice: choices[String(role.rawValue)]!) }
      s.routes = routes
    }
    try persist(s)
    await DeviceActivationService.shared.refresh()
    await inspectSelectedMain()
  }
  func clearForLocalReset() throws {
    let done = try SleepExitFence.shared.enter(); defer { done() }
    let code = SecItemDelete(fields as CFDictionary)
    guard code == errSecSuccess || code == errSecItemNotFound else { throw ServiceError("无法清除本机账号") }
    cached = State(); temporaryPrivateOwner = nil; packGeneration &+= 1
  }
  func forgetSession(_ reviewed: Identity) throws {
    guard let live = try state().accounts.first(where:{ $0.id == reviewed.id }),
      live.header == reviewed.header, live.mobileToken == reviewed.mobileToken else { throw ServiceError("登录信息已变更，请重新选择") }
    try forget(reviewed.id)
  }
  func select(_ id: String?) async throws {
    var s = try state()
    guard id == nil || s.accounts.contains(where: { $0.id == id }) else { return }
    s.active = id
    try persist(s)
    await DeviceActivationService.shared.refresh()
    await inspectSelectedMain()
  }
  func forget(_ id: String) throws {
    var s = try state()
    var routes = s.effectiveRoutes
    routes.remove(id)
    s.routes = routes
    s.accounts.removeAll { $0.id == id }
    if s.active == id { s.active = s.accounts.first?.id }
    try persist(s)
  }
}
@MainActor final class AccountContext: ObservableObject {
  @Published private(set) var state = AccountJar.State()
  @Published var issue: String?
  private var refreshID = UUID()
  private var activationTask: Task<Void, Never>?
  private var invalidationObserver: NSObjectProtocol?
  init() {
    invalidationObserver = NotificationCenter.default.addObserver(forName: InvalidWebSession.notification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor [weak self] in await self?.refresh() }
    }
  }
  deinit { if let invalidationObserver { NotificationCenter.default.removeObserver(invalidationObserver) } }
  func refresh() async {
    let id = UUID(); refreshID = id
    do {
      let next = try await AccountJar.shared.presentedState()
      guard refreshID == id, !Task.isCancelled else { return }
      let changed = state.active != next.active
      let video = next.owner(.role(.video)) ?? ""
      let videoChanged = (state.owner(.role(.video)) ?? "") != video
      ProfileStore.shared.activate(next)
      state = next
      // Publish local identity immediately; activation may take a network timeout.
      activationTask?.cancel()
      activationTask = Task { await DeviceActivationService.shared.refresh() }
      if changed { AccountBulletRules.shared.changedAccount() }
      if videoChanged { await Downloads.shared.suspendOtherOwners(video) }
    } catch { if refreshID == id, !Task.isCancelled { issue = error.localizedDescription } }
  }
  func select(_ id: String?) async {
    do {
      try await AccountJar.shared.select(id)
      await refresh()
    } catch { issue = error.localizedDescription }
  }
  func forget(_ id: String) async {
    do {
      try await AccountJar.shared.forget(id)
      AccountBulletRules.shared.forget(id)
      await refresh()
    } catch { issue = error.localizedDescription }
  }
}
