import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
#if canImport(UIKit)
  import UIKit
#endif

struct DeviceActivationContext: Sendable {
  let web: WebSessionSnapshot, snapshot: DeviceActivation.Snapshot
  init(web: WebSessionSnapshot, generation: UInt64) throws {
    self.web = web
    let sentCookies = WebCookieJar.values(web.legacyCookies, web.storedCookies, for: DeviceActivation.url)
    var credentials = sentCookies.filter { WebCookieJar.core.contains($0.key) || ["buvid3", "buvid4"].contains($0.key) }
    credentials["access_key"] = web.token
    let credential = try JSONSerialization.data(withJSONObject: credentials, options: [.sortedKeys])
    var choices = Dictionary(uniqueKeysWithValues: AccountRole.allCases.map { (String($0.rawValue), web.routes.choice($0)) })
    choices["active"] = web.active ?? ""
    let routing = try JSONSerialization.data(withJSONObject: choices, options: [.sortedKeys])
    snapshot = .init(owner: web.owner, device: web.device, cookie: web.header(for: DeviceActivation.url),
      credential: String(decoding: credential, as: UTF8.self), routing: String(decoding: routing, as: UTF8.self), generation: generation)
  }
}

extension AccountJar {
  func deviceActivationContext(owner: String?, requireReferenced: Bool = true) throws -> DeviceActivationContext {
    let state = try presentedState()
    guard !requireReferenced || AccountRole.allCases.contains(where: { state.owner(.role($0)) == owner })
    else { throw CancellationError() }
    // webSnapshot can create the missing local buvid3, advancing the store revision.
    let web = try webSnapshot(owner: owner)
    return try .init(web: web, generation: packStamp().generation)
  }
}

/// Called after account loading, login/import, role changes and device changes.
/// Only named accounts need the upstream activation POST; anonymous startup initializes its SPI cookies.
actor DeviceActivationService {
  typealias Send = @Sendable (URLRequest) async throws -> DeviceActivation.Response
  typealias Payload = @Sendable () async throws -> DeviceActivation.Payload
  static let shared = DeviceActivationService()
  private let jar: AccountJar, send: Send, payload: Payload
  private let client = DeviceActivationClient()
  private var revision: UInt64 = 0
  private var guestCompleted = Set<DeviceActivation.Snapshot.Identity>()
  private var guestPending: (id: UUID, snapshot: DeviceActivation.Snapshot, task: Task<DeviceActivationContext, Error>)?
  private(set) var issues: [String: String] = [:]
  init(jar: AccountJar = .shared, send: @escaping Send = { try await DeviceActivationService.transfer($0) },
    payload: @escaping Payload = { try await DeviceActivationService.platform() }) {
    self.jar = jar; self.send = send; self.payload = payload
  }
  private static func transfer(_ request: URLRequest) async throws -> DeviceActivation.Response {
    #if canImport(UIKit)
      let response = try await BiliAPI.shared.session.response(for: request)
      return .init(data: response.data, status: response.http.statusCode, cookies: response.cookies, url: response.http.url)
    #else
      throw URLError(.unsupportedURL)
    #endif
  }
  private static func platform() async throws -> DeviceActivation.Payload {
    #if canImport(UIKit)
      return await MainActor.run {
        let device = UIDevice.current
        let platform = device.systemName + " " + device.systemVersion + "; " + device.model
        var random = SystemRandomNumberGenerator()
        return .init(platform: platform, entropy: Data((0..<36).map { _ in UInt8.random(in: .min ... .max, using: &random) }))
      }
    #else
      throw ServiceError("设备信息暂不可用")
    #endif
  }
  func refresh() async {
    revision &+= 1; let stamp = revision
    async let guest: Void = refreshGuest()
    var contexts: [DeviceActivationContext] = []
    if let state = try? await jar.presentedState() {
      var owners = Set<String>()
      for role in AccountRole.allCases {
        guard let owner = state.owner(.role(role)), owners.insert(owner).inserted else { continue }
        do {
          let web = try await jar.webSession(.role(role))
          guard web.owner == owner else { continue }
          contexts.append(try await jar.deviceActivationContext(owner: owner))
        } catch { /* An unavailable role cannot prevent another account's initialization. */ }
      }
    }
    if stamp == revision {
      await client.retain(contexts.map(\.snapshot))
      await withTaskGroup(of: Void.self) { group in
        for context in contexts { group.addTask { await self.activate(context) } }
        await group.waitForAll()
      }
    }
    _ = await guest
  }
  private func activate(_ context: DeviceActivationContext) async {
    do {
      _ = try await client.activate(context.snapshot, payload: payload, current: { [jar] bound in
        try await jar.deviceActivationContext(owner: bound.owner).snapshot
      }, send: send, commit: { [jar] bound, response in
        guard let updated = try await jar.mergeResponseCookies(response.cookies, from: response.url ?? DeviceActivation.url, bound: context.web)
        else { throw CancellationError() }
        return try await DeviceActivationContext(web: updated, generation: jar.packStamp().generation).snapshot
      })
      issues.removeValue(forKey: context.web.owner ?? "")
    } catch is CancellationError {
    } catch {
      if let current = try? await jar.deviceActivationContext(owner: context.web.owner), context.snapshot.matches(current.snapshot) {
        issues[context.web.owner ?? ""] = error.localizedDescription
      }
    }
  }
  private func refreshGuest() async {
    do {
      let context = try await jar.deviceActivationContext(owner: nil, requireReferenced: false)
      _ = try await initializeGuest(context)
      issues.removeValue(forKey: "guest")
    } catch is CancellationError {
    } catch { issues["guest"] = error.localizedDescription }
  }
  private func initializeGuest(_ context: DeviceActivationContext) async throws -> DeviceActivationContext {
    if guestCompleted.contains(context.snapshot.identity) { return context }
    if let pending = guestPending {
      if pending.snapshot.matches(context.snapshot) { return try await pending.task.value }
      pending.task.cancel(); guestPending = nil
    }
    let id = UUID(), jar = self.jar, send = self.send
    let task = Task {
      try Task.checkCancellation()
      let response = try await send(DeviceActivation.fingerRequest())
      try Task.checkCancellation()
      let current = try await jar.deviceActivationContext(owner: nil, requireReferenced: false)
      guard context.snapshot.matches(current.snapshot) else { throw CancellationError() }
      let cookies = try DeviceActivation.fingerCookies(response)
      guard let updated = try await jar.mergeResponseCookies(cookies, from: DeviceActivation.fingerURL, bound: context.web)
      else { throw CancellationError() }
      try Task.checkCancellation()
      let result = try await DeviceActivationContext(web: updated, generation: jar.packStamp().generation)
      guard result.snapshot.matches(try await jar.deviceActivationContext(owner: nil, requireReferenced: false).snapshot)
      else { throw CancellationError() }
      return result
    }
    guestPending = (id, context.snapshot, task)
    do {
      let updated = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
      guard guestPending?.id == id else { throw CancellationError() }
      guestPending = nil; guestCompleted.insert(updated.snapshot.identity)
      return updated
    } catch {
      if guestPending?.id == id { guestPending = nil }
      throw error
    }
  }
}
