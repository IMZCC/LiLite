import Foundation

extension AccountJar {
  func mobileRESTSession(_ use: AccountUse) async throws -> MobileREST.Session {
    let identity = try await current(use, credentials: .mobile)
    let state = try presentedState()
    let latest = state.accounts.first { $0.id == identity?.id }
    guard state.owner(use) == identity?.id, latest?.mobileToken == identity?.mobileToken,
      MobileDeviceID.use(latest?.archiveDevice) == MobileDeviceID.use(identity?.archiveDevice)
    else { throw ServiceError("账号授权已变更，请重试") }
    let routing: String
    switch use {
    case .role(let role): routing = String(role.rawValue) + ":" + state.effectiveRoutes.choice(role)
    case .history: routing = "history:" + state.effectiveRoutes.choice(.heartbeat)
    }
    return .init(owner: identity?.id, token: identity?.mobileToken,
      device: MobileDeviceID.use(identity?.archiveDevice), routing: routing)
  }
}

extension BiliAPI {
  func mobileREST(
    _ path: String, _ fields: [String: String], use: AccountUse,
    expectedAccount: String? = nil, requiresToken: Bool = false
  ) async throws -> (data: Data, session: MobileREST.Session) {
    let bound = try await AccountJar.shared.mobileRESTSession(use)
    if let expectedAccount, (bound.owner ?? "") != expectedAccount { throw ServiceError("账号已切换") }
    if requiresToken, bound.token?.isEmpty != false { throw ServiceError("请先完成移动端授权") }
    let request = try MobileREST.request(path: path, fields: fields, session: bound)
    let (data, response) = try await ConnectionRetry.current().perform(readOnly: !HTTP11Message.mutatingGET(path)) { _ in
      try await MobileREST.transfer(request, session: bound, current: {
        try await AccountJar.shared.mobileRESTSession(use)
      }, via: { try await self.session.data(for: $0) })
    }
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw ServiceError("请求未成功（\((response as? HTTPURLResponse)?.statusCode ?? 0)）")
    }
    return (data, bound)
  }
}
