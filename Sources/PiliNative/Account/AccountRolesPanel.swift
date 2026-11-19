import SwiftUI

struct AccountRolesPanel: View {
  @EnvironmentObject var accounts: AccountContext
  var body: some View {
    Form {
      Section {
        ForEach([AccountRole.heartbeat, .recommend, .video]) { role in
          Picker(
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
          } label: {
            SettingsRowLabel(title: role.title, symbol: Self.symbol(role), color: Self.color(role))
          }
        }
      } footer: {
        Text("未单独分配的请求使用主账号。游客不携带登录信息。")
      }
      if let h = accounts.state.owner(.history) {
        Section {
          LabeledContent {
            Text("UID " + h).monospacedDigit()
          } label: {
            SettingsRowLabel(title: "查看历史记录", symbol: "clock.arrow.circlepath", color: .indigo)
          }
        }
      }
      Section {
        NavigationLink { DeferredPage { AccountRoleExplanation() } } label: {
          SettingsRowLabel(title: "账号用途说明", symbol: "info.circle", color: .gray)
        }
      }
    }
    .navigationTitle("账号用途").navigationBarTitleDisplayMode(.inline)
  }
  static func symbol(_ role: AccountRole) -> String {
    switch role {
    case .heartbeat: "waveform.path.ecg"
    case .recommend: "sparkles.rectangle.stack"
    case .video: "play.rectangle"
    default: "person.crop.circle"
    }
  }
  static func color(_ role: AccountRole) -> Color {
    switch role {
    case .heartbeat: .pink
    case .recommend: .orange
    case .video: .blue
    default: .gray
    }
  }
}

private struct AccountRoleExplanation: View {
  var body: some View {
    List {
      Section {
        Text("用于互动、关注、收藏等操作，以及未单独分配用途的请求").font(.subheadline)
      } header: {
        Label("主账号", systemImage: "person.crop.circle")
      }
      ForEach([AccountRole.heartbeat, .recommend, .video]) { role in
        Section {
          ForEach(AccountRoutes.services.filter { $0.value == role }.map(\.key).sorted(), id: \.self) { service in
            Text(service).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
          }
        } header: {
          Label(role.title, systemImage: AccountRolesPanel.symbol(role))
        }
      }
    }
    .navigationTitle("账号用途说明").navigationBarTitleDisplayMode(.inline)
  }
}
