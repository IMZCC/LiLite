import SwiftUI

struct CookieLogin: View {
  @State private var input = ""
  @State private var busy = false
  @State private var error: String?
  @State private var request: Task<Void, Never>?
  @EnvironmentObject var accounts: AccountContext
  @Environment(\.dismiss) var dismiss
  var body: some View {
    Form {
      Section("哔哩哔哩 Cookie") {
        SecureField("粘贴自己的登录 Cookie", text: $input).textInputAutocapitalization(.never)
          .autocorrectionDisabled().privacySensitive()
        Button("登录") { request = Task { await login() } }.disabled(busy || input.isEmpty)
      }
      if busy { ProgressView() }
      if let error { Text(error).foregroundStyle(.secondary) }
    }.navigationTitle("Cookie 登录").onDisappear { request?.cancel(); input = "" }
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
