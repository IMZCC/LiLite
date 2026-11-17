import SwiftUI

extension BiliAPI {
  func claimMemberExperience(_ uid: String) async throws {
    guard let user = try await AccountJar.shared.current(), user.id == uid,
      let csrf = user.csrf, !csrf.isEmpty else { throw ServiceError("请重新登录当前账号") }
    var route = URLComponents()
    route.path = "/x/vip/experience/add"
    route.queryItems = [.init(name:"mid", value: uid), .init(name:"csrf", value: csrf)]
    guard let path = route.string else { throw URLError(.badURL) }
    try await submit(path, [:], expectedAccount: uid)
  }
}

struct MemberExperienceButton: View {
  let uid: String
  var refresh: (() -> Void)? = nil
  @EnvironmentObject private var accounts: AccountContext
  @State private var busy = false
  @State private var message: String?
  var body: some View {
    Button { Task { await claim() } } label: {
      HStack {
        SettingsRowLabel(title: "领取大会员经验", symbol: "star.circle.fill", color: .pink)
        Spacer(minLength: 8)
        if busy { ProgressView() }
      }
    }.foregroundStyle(.primary).disabled(busy || uid != accounts.state.active)
      .alert("大会员经验", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
        Button("好") {}
      } message: { Text(message ?? "") }
  }
  @MainActor private func claim() async {
    guard !busy, uid == accounts.state.active else { return }
    busy = true; defer { busy = false }
    do {
      try await BiliAPI.shared.claimMemberExperience(uid)
      guard uid == accounts.state.active else { return }
      message = "领取成功"; refresh?()
    } catch { if uid == accounts.state.active { message = error.localizedDescription } }
  }
}
