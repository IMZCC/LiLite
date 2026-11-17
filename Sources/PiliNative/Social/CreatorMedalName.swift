import SwiftUI

struct CreatorMedalName: View {
  let mid: Int64
  @EnvironmentObject private var accounts: AccountContext
  @State private var name: String?
  @State private var issue: String?
  @State private var busy = false
  private struct Medal: Decodable { let medal_name: String? }
  var body: some View {
    Button {
      if let name { UIPasteboard.general.string = name }
      else { Task { await load() } }
    } label: {
      LabeledContent("粉丝勋章", value: name ?? (busy ? "读取中" : "查看"))
    }.disabled(busy)
      .accessibilityHint(name != nil ? "轻点拷贝勋章名" : "轻点查看勋章名")
      .alert("粉丝勋章", isPresented: Binding(get:{ issue != nil },set:{ if !$0 { issue = nil } })) {
        Button("好") {}
      } message:{ Text(issue ?? "") }
      .onChange(of: accounts.state.active) { _,_ in name = nil; issue = nil }
  }
  @MainActor private func load() async {
    guard !busy else { return }
    busy = true; defer { busy = false }
    let owner = accounts.state.active
    do {
      let res = try await BiliAPI.shared.read("/live_user/v1/Master/info", ["uid":String(mid)], host:"api.live.bilibili.com",
        expectedAccount:owner ?? "", as:Medal.self)
      guard owner == accounts.state.active else { return }
      if let value = res.medal_name, !value.isEmpty { name = value }
      else { issue = "暂无粉丝勋章" }
    } catch { if owner == accounts.state.active { issue = error.localizedDescription } }
  }
}
