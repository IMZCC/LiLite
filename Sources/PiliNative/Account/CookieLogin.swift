import SwiftUI

struct CookieLogin: View {
  @State private var input = ""
  @State private var busy = false
  @State private var error: String?
  @State private var request: Task<Void, Never>?
  @EnvironmentObject var accounts: AccountContext
  @Environment(\.dismiss) var dismiss
  var body: some View {
    LoginPane(headline: "使用 Cookie 登录", note: "使用 App 端接口实现的功能将不可用", footnote: LoginCopy.trusted) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "birthday.cake").font(.body.weight(.medium)).foregroundStyle(.secondary)
          .frame(width: 24).padding(.top, 14)
        TextField("Cookie", text: $input, axis: .vertical).lineLimit(1...10)
          .font(.callout.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
          .privacySensitive().padding(.vertical, 13)
          .onChange(of: input) { _, value in
            let stripped = value.filter { !$0.isWhitespace || $0 == " " }
            if stripped != value { input = stripped }
          }
        if !input.isEmpty {
          Button { input = "" } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
          }.buttonStyle(.plain).padding(.top, 14).accessibilityLabel("清除")
        }
      }
      .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1) }
      if let error {
        Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
      }
      LoginSubmit(busy: busy) { request = Task { await login() } }.disabled(busy || input.isEmpty)
    }
    .onDisappear { request?.cancel(); input = "" }
  }
  private func login() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      let generation = try await AccountJar.shared.packStamp().generation
      try Task.checkCancellation()
      guard input.utf8.count <= 32768, !input.contains("\n"), !input.contains("\r") else {
        throw ServiceError("Cookie 格式不正确")
      }
      var values: [String: String] = [:]
      for part in input.split(separator: ";") {
        let fields = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2 else { continue }
        let key = fields[0].trimmingCharacters(in: .whitespaces)
        if ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"].contains(key) {
          let value = fields[1].trimmingCharacters(in: .whitespaces)
          guard value.utf8.allSatisfy({ $0 >= 33 && $0 < 127 }) else {
            throw ServiceError("Cookie 中含有无效字符")
          }
          values[key] = value
        }
      }
      guard !(values["SESSDATA"] ?? "").isEmpty, !(values["bili_jct"] ?? "").isEmpty else {
        throw ServiceError("缺少 SESSDATA 或 bili_jct")
      }
      let login = try await WebLoginIdentity.verify(values)
      try Task.checkCancellation()
      try await AccountJar.shared.add(login.cookies, label: login.name, expectedGeneration: generation)
      input = ""
      await accounts.refresh()
      dismiss()
    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
  }
}
