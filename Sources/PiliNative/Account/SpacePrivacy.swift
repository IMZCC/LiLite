import SwiftUI

struct SpacePrivacy: View {
  let uid: String
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.dismiss) private var dismiss
  private struct Payload: Decodable { let privacy: SpacePrivacyValues }
  @State private var original: [String: Int] = [:]
  @State private var values: [String: Int] = [:]
  @State private var issue: String?
  @State private var ready = false
  @State private var busy = false
  @State private var leaving = false
  @State private var reload = 0
  private var dirty: Bool { ready && values != original }
  var body: some View {
    Form {
      if !ready && busy { ProgressView() }
      if let issue { Text(issue); Button("重新载入") { reload += 1 }.disabled(busy) }
      if ready {
        ForEach(SpacePrivacyValues.sections.indices, id: \.self) { ix in
          Section(SpacePrivacyValues.sections[ix].0) {
            ForEach(SpacePrivacyValues.sections[ix].1) { field in
              Toggle(isOn: Binding(
                get: { values[field.id] == (field.reverse ? 0 : 1) },
                set: { values[field.id] = $0 != field.reverse ? 1 : 0 })) {
                  VStack(alignment: .leading) {
                    Text(field.label)
                    if values[field.id] == nil { Text("未指定").font(.caption).foregroundStyle(.secondary) }
                  }
                }
            }
          }.disabled(busy)
        }
      }
    }.navigationTitle("空间隐私").navigationBarBackButtonHidden(dirty)
      .toolbar {
        if dirty {
          ToolbarItem(placement: .cancellationAction) { Button("返回") { leaving = true }.disabled(busy) }
        }
        ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { await save() } }.disabled(busy || !dirty) }
      }
      .confirmationDialog("保存空间隐私更改？", isPresented: $leaving, titleVisibility: .visible) {
        Button("保存并返回") { Task { await save(returning: true) } }
        Button("放弃更改", role: .destructive) { dismiss() }
      }
      .task(id: "\(uid):\(accounts.state.active ?? ""):\(reload)") { await load() }
  }
  private func read() async throws -> [String: Int] {
    let r = try await BiliAPI.shared.read("/x/space/setting/app", ["mid": uid], expectedAccount: uid, as: Payload.self)
    return r.privacy.values
  }
  @MainActor private func load() async {
    ready = false; original = [:]; values = [:]; issue = nil
    guard uid == accounts.state.active else { busy = false; issue = "账号已切换"; return }
    busy = true
    defer { if !Task.isCancelled { busy = false } }
    do {
      let current = try await read()
      try Task.checkCancellation()
      guard uid == accounts.state.active else { return }
      original = current; values = current; ready = true
    } catch { if !Task.isCancelled, uid == accounts.state.active { issue = error.localizedDescription } }
  }
  @MainActor private func save(returning: Bool = false) async {
    guard !busy, dirty, uid == accounts.state.active else { return }
    busy = true
    defer { busy = false }
    do {
      let snapshot = values, before = original
      let latest = try await read()
      let merged: [String:Int]
      do { merged = try SpacePrivacyValues.merge(baseline: before, draft: snapshot, latest: latest) }
      catch { throw ServiceError("这些设置已在其他设备更改，请重新载入") }
      if latest != merged {
        guard let account = try await AccountJar.shared.current(), account.id == uid, let csrf = account.csrf else { throw ServiceError("请重新登录") }
        var c = URLComponents(); c.path = "/x/space/privacy/batch/modify"
        c.queryItems = [.init(name:"csrf", value: csrf)]
        guard let path = c.string else { throw URLError(.badURL) }
        try await BiliAPI.shared.submit(path, merged.mapValues(String.init), expectedAccount: uid)
      }
      guard uid == accounts.state.active else { return }
      original = merged; values = merged; issue = nil
      if returning { dismiss() }
    } catch { if uid == accounts.state.active { issue = error.localizedDescription } }
  }
}
