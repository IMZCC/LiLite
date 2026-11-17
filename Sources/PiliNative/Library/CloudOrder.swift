import SwiftUI

struct CloudOrder: View {
  var uid: String?
  var expectedGroupOwner: String? = nil
  var saved: () -> Void
  struct Row: Identifiable { let id: String, name: String }
  @State private var rows: [Row] = []
  @State private var locked: [Row] = []
  @State private var owner: String?
  @State private var original: [String] = []
  @State private var busy = false
  @State private var issue: String?
  @State private var retry = 0
  @Environment(\.dismiss) var dismiss
  var body: some View {
    List {
      ForEach(locked) { fixed in Label(fixed.name, systemImage: "lock") }
      ForEach(rows) { r in Text(r.name) }.onMove { rows.move(fromOffsets: $0, toOffset: $1) }
      if busy { ProgressView() }
      if let issue {
        Text(issue).foregroundStyle(.secondary)
        Button("重试") { retry += 1 }
      }
    }.navigationTitle(uid == nil ? "关注分组排序" : "收藏夹排序").environment(\.editMode, .constant(.active))
      .toolbar {
        Button("保存") { Task { await save() } }.disabled(busy || rows.map(\.id) == original)
      }.task(id: retry) {
        busy = true
        defer { busy = false }
        do {
          guard let current = try await AccountJar.shared.current()?.id,
            (uid ?? expectedGroupOwner) == nil || (uid ?? expectedGroupOwner) == current
          else { throw ServiceError("账号已切换") }
          owner = current
          if let uid {
            let folders = try await BiliAPI.shared.folders(uid: uid, expectedAccount: current).map {
              Row(id: "\($0.id)", name: $0.title)
            }
            locked = Array(folders.prefix(1))
            rows = Array(folders.dropFirst())
          } else {
            let groups = try await BiliAPI.shared.read("/x/relation/tags", [:], expectedAccount: current, as: [FollowGroup].self)
            func row(_ g: FollowGroup) -> Row { .init(id: String(g.id), name: (g.name ?? "分组") + "（" + String(g.count ?? 0) + "）") }
            locked = [.init(id: "all", name: "全部关注")] + groups.filter { !FollowGroupCommand.custom($0.id) }.map(row)
            rows = groups.filter { FollowGroupCommand.custom($0.id) }.map(row)
          }
          original = rows.map(\.id)
          issue = nil
        } catch { issue = error.localizedDescription }
      }
  }
  private func save() async {
    guard !busy, let owner else { return }
    busy = true
    defer { busy = false }
    do {
      if uid == nil {
        let cmd = try FollowGroupCommand(.order(rows.compactMap { Int($0.id) }), owner: owner)
        try await cmd.apply(active: try await AccountJar.shared.current()?.id) { path, fields, account in
          try await BiliAPI.shared.submit(path, fields, expectedAccount: account)
        }
      } else {
        let order = (locked + rows).map(\.id).joined(separator: ",")
        try await BiliAPI.shared.submit("/x/v3/fav/folder/sort", ["sort": order], expectedAccount: owner)
      }
      saved()
      dismiss()
    } catch { issue = error.localizedDescription }
  }
}
