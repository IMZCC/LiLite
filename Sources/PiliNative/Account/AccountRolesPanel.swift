import SwiftUI

struct AccountRolesPanel: View {
  @EnvironmentObject var accounts: AccountContext
  var body: some View {
    Form {
      Section("账号用途") {
        ForEach([AccountRole.heartbeat, .recommend, .video]) { role in
          Picker(
            role.title,
            selection: Binding(
              get: { accounts.state.effectiveRoutes.choice(role) },
              set: { choice in
                Task {
                  do {
                    try await AccountJar.shared.assign(role, choice: choice)
                    await accounts.refresh()
                  } catch { accounts.issue = error.localizedDescription }
                }
              })
          ) {
            Text("跟随主账号").tag(AccountRoutes.follow)
            Text("游客").tag(AccountRoutes.guest)
            ForEach(accounts.state.accounts) { a in Text(a.label + " · " + a.id).tag(a.id) }
          }
        }
      }
      if let h = accounts.state.owner(.history) { LabeledContent("查看历史记录", value: "UID " + h) }
      NavigationLink("账号用途说明") { AccountRoleExplanation() }
    }.navigationTitle("账号用途")
  }
}

private struct AccountRoleExplanation: View {
  var body: some View {
    List {
      Section("主账号") { Text("用于互动、关注、收藏等操作，以及未单独分配用途的请求") }
      ForEach([AccountRole.heartbeat, .recommend, .video]) { role in
        Section(role.title) {
          ForEach(AccountRoutes.services.filter { $0.value == role }.map(\.key).sorted(), id: \.self) { service in
            Text(service).font(.footnote.monospaced()).textSelection(.enabled)
          }
        }
      }
    }.navigationTitle("账号用途说明")
  }
}
