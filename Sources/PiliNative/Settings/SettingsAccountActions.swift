import SwiftUI

struct SettingsAccountActions: View {
  @EnvironmentObject private var accounts: AccountContext
  @State private var selection = Set<String>()
  @State private var review: [Identity]?
  @State private var message: String?
  @State private var busy = false
  var body: some View {
    Form {
      Section {
        ForEach(accounts.state.accounts) { a in
          Button {
            guard accounts.state.active != a.id else { return }
            TouchFeedback.light()
            Task { await accounts.select(a.id) }
          } label: {
            accountRow(a.label, uid: a.id, current: accounts.state.active == a.id)
          }.buttonStyle(.plain)
        }
        Button {
          guard accounts.state.active != nil else { return }
          Task { await accounts.select(nil) }
        } label: {
          HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.dashed").font(.system(size: 30)).foregroundStyle(.secondary)
              .frame(width: 44, height: 44)
            Text("游客模式").foregroundStyle(.primary)
            Spacer()
            if accounts.state.active == nil { checkmark }
          }.contentShape(Rectangle())
        }.buttonStyle(.plain)
        NavigationLink { QRLoginView() } label: {
          Label("添加账号", systemImage: "plus").labelStyle(SettingsIconLabelStyle(color: .blue))
        }
      } header: {
        Text("账号")
      } footer: {
        Text("点按切换当前账号。")
      }
      Section {
        NavigationLink { AccountRolesPanel() } label: {
          Label("账号用途", systemImage: "person.2.badge.gearshape.fill").labelStyle(SettingsIconLabelStyle(color: .indigo))
        }
      } footer: {
        Text("可以让推荐、播放记录等使用不同的账号。")
      }
      if !accounts.state.accounts.isEmpty {
        Section {
          ForEach(accounts.state.accounts) { a in
            Button {
              withAnimation(.snappy(duration: 0.2)) {
                if selection.contains(a.id) { selection.remove(a.id) } else { selection.insert(a.id) }
              }
            } label: {
              HStack(spacing: 12) {
                Image(systemName: selection.contains(a.id) ? "checkmark.circle.fill" : "circle")
                  .font(.title3).foregroundStyle(selection.contains(a.id) ? Color.red : Color.secondary)
                  .contentTransition(.symbolEffect(.replace))
                Text(a.label).foregroundStyle(.primary)
                Text("UID " + a.id).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
              }.contentShape(Rectangle())
            }.buttonStyle(.plain)
          }
          Button("退出所选账号", role: .destructive) {
            review = accounts.state.accounts.filter { selection.contains($0.id) }
          }.disabled(selection.isEmpty)
        } header: {
          Text("退出登录")
        } footer: {
          Text("可以只从本机移除，也可以同时让服务端的登录失效。")
        }
      }
      if busy {
        HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
      }
      if let message {
        Text(message).font(.footnote).foregroundStyle(.secondary)
      }
    }.disabled(busy).navigationTitle("切换与退出账号")
      .confirmationDialog(
        "退出所选账号？", isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } }),
        presenting: review
      ) { entries in
        Button("仅从本机移除", role: .destructive) { Task { await apply(entries, revoke: false) } }
        Button("退出服务端登录并移除", role: .destructive) { Task { await apply(entries, revoke: true) } }
      } message: {
        Text($0.map(\.id).joined(separator: "、"))
      }
  }
  @ObservedObject private var store = ProfileStore.shared
  private var checkmark: some View {
    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
      .transition(.scale.combined(with: .opacity))
  }
  private func accountRow(_ label: String, uid: String, current: Bool) -> some View {
    let profile = store.profiles[uid].flatMap { String($0.mid) == uid ? $0 : nil }
    return HStack(spacing: 12) {
      ProfileAvatar(url: profile?.face.flatMap(httpsURL), size: 44)
      VStack(alignment: .leading, spacing: 2) {
        Text(profile?.uname ?? label).foregroundStyle(.primary).lineLimit(1)
        Text("UID " + uid).font(.caption).foregroundStyle(.secondary).monospacedDigit()
      }
      Spacer()
      if current { checkmark }
    }
    .contentShape(Rectangle())
    .animation(.snappy(duration: 0.2), value: current)
  }
  @MainActor private func apply(_ entries: [Identity], revoke: Bool) async {
    guard let finished = try? SleepExitFence.shared.enter() else { return }; defer { finished() }
    guard !busy else { return }
    busy = true
    defer { busy = false }
    message = nil
    var removed = [String]()
    var failures = [String]()
    for entry in entries {
      do {
        guard
          let live = try await AccountJar.shared.state().accounts.first(where: { $0.id == entry.id }
          ), live.header == entry.header, live.mobileToken == entry.mobileToken
        else { throw ServiceError("账号已变更") }
        if revoke { try await revokeRemote(try await AccountJar.shared.validateImported(entry)) }
        try await AccountJar.shared.forgetSession(entry)
        AccountBulletRules.shared.forget(entry.id)
        removed.append(entry.id)
        selection.remove(entry.id)
      } catch { failures.append("UID " + entry.id + "：" + error.localizedDescription) }
    }
    await accounts.refresh()
    message =
      ([removed.isEmpty ? nil : "已退出 " + String(removed.count) + " 个账号"].compactMap { $0 }
      + failures).joined(separator: "\n")
  }
  private func revokeRemote(_ identity: Identity) async throws {
    guard let csrf = identity.csrf else { throw ServiceError("登录信息不完整") }
    let req = try AccountExitRequest.make(header: identity.header, csrf: csrf)
    let config = URLSessionConfiguration.ephemeral
    let proxy = APIProxy.current()
    proxy.apply(to: config)
    config.httpShouldSetCookies = false
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    config.urlCache = nil
    let session = URLSession(
      configuration: config, delegate: APIRedirectPolicy(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await BiliServiceSession(native: session, proxy: proxy).data(
      for: req)
    try AccountExitRequest.check(bytes, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
  }
}
