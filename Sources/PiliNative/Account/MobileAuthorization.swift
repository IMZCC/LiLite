import PiliWire
import SwiftUI

extension BiliAPI {
  /// Use the token alone for identity lookup. The web cookie must not satisfy this check.
  func mobileIdentity(_ token: String) async throws -> Int64 {
    try await ImportedCredentialProbe.mobileOwner(token)
  }
  nonisolated func instantMessaging(for uid: String) -> IMGateway {
    IMGateway { method, body in
      try await self.mobileCall(
        method.path, body, uid: uid, needsToken: true,
        readOnly: [.main, .secondary, .update, .detail, .settings, .keywords, .unread, .shareList, .history].contains(
          method))
    }
  }
  nonisolated func commentService(for uid: String?) -> ReplyGateway {
    ReplyGateway { method, body in
      try await self.mobileCall(method.path, body, uid: uid, needsToken: false, readOnly: true)
    }
  }
  nonisolated func socialService(for uid: String?) -> DynamicGateway {
    DynamicGateway { method, body in
      try await self.mobileCall(method.path, body, uid: uid, needsToken: false, readOnly: true)
    }
  }
  func guestSubtitleTracks(aid: Int64, cid: Int64) async throws -> [SubtitleGateway.Track] {
    try await SubtitleGateway.tracks(aid: aid, cid: cid) { body in
      try await self.mobileCall(
        SubtitleGateway.path, body, uid: nil, needsToken: false, readOnly: true)
    }
  }
  func mobileCall(
    _ path: String, _ data: Data, uid: String?, needsToken: Bool, readOnly: Bool
  ) async throws
    -> GatewayReply
  {
    let identity = try await AccountJar.shared.current(credentials:.mobile)
    guard identity?.id == uid else { throw ServiceError("账号已切换") }
    let token = identity?.mobileToken
    if needsToken && token?.isEmpty != false { throw ServiceError("请先完成移动端授权") }
    guard path.hasPrefix("/bilibili."), !path.contains("?"), !path.contains("#"),
      let target = URL(string:"https://app.bilibili.com" + path), target.host == "app.bilibili.com",
      target.user == nil, target.password == nil, target.port == nil else {throw URLError(.unsupportedURL)}
    var r = URLRequest(
      url: target,
      cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
    r.httpMethod = "POST"
    r.httpBody = data
    r.httpShouldHandleCookies = false
    r.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
    r.setValue("identity,gzip", forHTTPHeaderField: "grpc-accept-encoding")
    if let token, !token.isEmpty {
      r.setValue("identify_v1 " + token, forHTTPHeaderField: "Authorization")
    }
    let device = MobileDeviceID.use(identity?.archiveDevice)
    let info = Bundle.main.infoDictionary
    let headers = try ClientMetadata.headers(device: device, token: token,
      build: Int32(info?["CFBundleVersion"] as? String ?? "") ?? 1, version: info?["CFBundleShortVersionString"] as? String ?? "1.0")
    for (name, value) in headers { r.setValue(value, forHTTPHeaderField: name) }
    r.setValue("PiliNative/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
    let original = r
    let (bytes, raw) = try await ConnectionRetry.current().perform(readOnly: readOnly) { _ in
      let fresh = try await AccountJar.shared.current(credentials:.mobile)
      guard fresh?.id == uid, fresh?.mobileToken == token, MobileDeviceID.use(fresh?.archiveDevice) == device else { throw ServiceError("账号授权已变更") }
      return try await self.session.data(for: original)
    }
    try Task.checkCancellation()
    let latest = try await AccountJar.shared.current(credentials:.mobile)
    guard latest?.id == uid, latest?.mobileToken == token, MobileDeviceID.use(latest?.archiveDevice) == device
    else { throw ServiceError("账号授权已变更") }
    guard let h = raw as? HTTPURLResponse else { throw ServiceError("无法连接消息服务") }
    let fields = Dictionary(
      uniqueKeysWithValues: ["grpc-status", "grpc-status-details-bin", "grpc-message", "grpc-encoding"].compactMap { k in
        h.value(forHTTPHeaderField: k).map { (k, $0) }
      })
    return .init(status: h.statusCode, contentType: h.mimeType ?? "", headers: fields, data: bytes)
  }
}
struct MobileAuthorization: View {
  let uid: String
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.dismiss) private var dismiss
  @State private var token = ""
  @State private var busy = false
  @State private var error: String?
  @State private var revoke = false
  @State private var request: Task<Void, Never>?
  private var attached: Bool { accounts.state.accounts.first { $0.id == uid }?.mobileToken != nil }
  var body: some View {
    Form {
      Section {
        VStack(spacing: 10) {
          Image(systemName: attached ? "checkmark.shield.fill" : "iphone.badge.exclamationmark")
            .font(.system(size: 44)).foregroundStyle(attached ? Color.green : Color.orange)
            .symbolRenderingMode(.hierarchical)
          Text(attached ? "已授权移动端接口" : "尚未授权移动端接口").font(.headline)
          Text("私信、动态发布与部分 App 端功能需要移动端授权").font(.footnote)
            .foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
      }
      Section {
        NavigationLink { MobileClientLoginView(expectedUID: uid) } label: {
          SettingsRowLabel(title: attached ? "重新授权" : "扫码或登录授权", symbol: "qrcode.viewfinder", color: .blue)
        }
      }
      Section {
        SecureField("Access Token", text: $token).autocorrectionDisabled()
          .textInputAutocapitalization(.never).privacySensitive().disabled(busy)
        Button {
          request = Task { await validate() }
        } label: {
          HStack {
            Text(attached ? "更换授权" : "绑定到当前账号")
            if busy { Spacer(); ProgressView() }
          }
        }
        .disabled(token.isEmpty || busy)
      } header: {
        Text("使用我的移动端令牌")
      } footer: {
        if let error { Text(error).foregroundStyle(.red) }
      }
      if attached {
        Section {
          Button("从此设备移除授权", role: .destructive) { revoke = true }
        }
      }
    }.navigationTitle("移动端授权").navigationBarTitleDisplayMode(.inline)
    .confirmationDialog("移除移动端授权？", isPresented: $revoke) {
      Button("移除", role: .destructive) {
        Task {
          do {
            try await AccountJar.shared.setMobileToken(nil, for: uid)
            await accounts.refresh()
          } catch { self.error = error.localizedDescription }
        }
      }
    }.onDisappear { request?.cancel(); token = "" }
  }
  @MainActor private func validate() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      let generation = try await AccountJar.shared.packStamp().generation
      let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
      guard try await BiliAPI.shared.mobileIdentity(t) == Int64(uid) else {
        throw ServiceError("令牌与当前账号不匹配")
      }
      try Task.checkCancellation()
      try await AccountJar.shared.setMobileToken(t, for: uid, expectedGeneration: generation)
      token = ""
      await accounts.refresh()
      if !Task.isCancelled { dismiss() }
    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
  }
}
