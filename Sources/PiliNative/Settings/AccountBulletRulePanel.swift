import SwiftUI

struct AccountBulletRulePanel: View {
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    Group {
      if let owner = accounts.state.active { RuleList(owner: owner).id(owner) }
      else { ContentUnavailableView("登录后管理账号屏蔽规则", systemImage: "person.crop.circle") }
    }.navigationTitle("账号弹幕屏蔽")
  }
}

private struct RuleList: View {
  let owner: String
  @ObservedObject private var store = AccountBulletRules.shared
  @State private var type = 0
  @State private var busy = false
  @State private var editor = false
  @State private var draft = ""
  @State private var original: CloudBulletRule?
  @State private var removing: CloudBulletRule?
  @State private var issue: String?
  private let labels = ["关键词", "正则", "用户"]
  private var rows: [CloudBulletRule] { store.rows(owner) }
  var body: some View {
    List {
      Picker("类别", selection: $type) {
        ForEach(0..<3) { index in Text(labels[index] + " (\(rows.filter { $0.type == index }.count))").tag(index) }
      }.pickerStyle(.segmented)
      let filtered = rows.filter { $0.type == type }
      if filtered.isEmpty && !busy { Text("暂无规则").foregroundStyle(.secondary) }
      ForEach(filtered) { row in
        HStack {
          Text(row.display).textSelection(.enabled)
          Spacer()
          if type != 2 {
            Button { original = row; draft = row.display; editor = true } label: { Image(systemName: "pencil") }
              .accessibilityLabel("编辑规则").buttonStyle(.borderless)
          }
          Button(role: .destructive) { removing = row } label: { Image(systemName: "trash") }
            .accessibilityLabel("删除规则").buttonStyle(.borderless)
        }
      }
      if busy { ProgressView() }
      if let issue, !issue.isEmpty { Text(issue).foregroundStyle(.secondary) }
    }.disabled(busy).piliRefreshable { await synchronize() }.task { await synchronize() }
      .toolbar {
        Button { draft = ""; original = nil; editor = true } label: { Image(systemName: "plus") }
          .accessibilityLabel("添加规则").disabled(busy)
      }.alert(original == nil ? "添加\(labels[type])规则" : "编辑规则", isPresented: $editor) {
        TextField(type == 2 ? "用户 UID" : labels[type], text: $draft)
          .keyboardType(type == 2 ? .numberPad : .default).autocorrectionDisabled()
          .textInputAutocapitalization(.never)
        Button("取消", role: .cancel) {}
        Button("保存") {
          let value = draft, previous = original, kind = type
          Task { await perform { try await store.update(owner, type: kind, input: value, replacing: previous) } }
        }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }.confirmationDialog("删除这条屏蔽规则？", isPresented: Binding(
        get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { row in
          Button("删除", role: .destructive) { Task { await perform { try await store.remove(row, owner: owner) } } }
        }
  }
  private func perform(_ action: () async throws -> Void) async {
    guard !busy else { return }
    busy = true; issue = nil
    defer { busy = false }
    do { try await action() } catch { issue = error.localizedDescription }
  }
  private func synchronize() async {
    await perform { issue = try await store.sync(owner) }
  }
}
