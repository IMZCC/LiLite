import SwiftUI

struct PickFolder: View {
  let uid: String, aid: Int64
  var resourceType = 2
  @Environment(\.dismiss) var dismiss
  @State private var folders: [Folder] = []
  @State private var original: Set<Int64> = []
  @State private var selected: Set<Int64> = []
  @State private var issue: String?
  @State private var limitIssue: String?
  @State private var loading = true
  @State private var saving = false
  @State private var creating = false
  @State private var revision = 0
  var body: some View {
    List {
      if loading { ProgressView() }
      if let limitIssue { Text(limitIssue).foregroundStyle(.secondary) }
      if let issue {
        Text(issue).foregroundStyle(.secondary)
        Button("重新加载") { revision += 1 }
      }
      if !loading && issue == nil && folders.isEmpty { Text("暂无收藏夹").foregroundStyle(.secondary) }
      ForEach(folders) { f in
        Button {
          if selected.contains(f.id) {
            selected.remove(f.id)
          } else if !original.contains(f.id), let count = f.media_count, let attr = f.attr,
            count >= ((attr & 2) == 0 ? 50_000 : 1_000)
          {
            limitIssue = "这个收藏夹已满"
          } else {
            selected.insert(f.id)
          }
        } label: {
          HStack {
            Label(f.title, systemImage: "folder")
            Spacer()
            Image(systemName: selected.contains(f.id) ? "checkmark.circle.fill" : "circle")
          }
        }.accessibilityAddTraits(selected.contains(f.id) ? [.isSelected] : [])
      }.disabled(loading || saving)
      Button("新建收藏夹") { creating = true }.disabled(loading || saving)
    }.navigationTitle("收藏夹").toolbar {
      Button("保存") { Task { await save() } }.disabled(saving || loading || folders.isEmpty)
    }
    .task(id: revision) {
      loading = true
      defer { loading = false }
      do {
        let rows = try await BiliAPI.shared.folders(
          uid: uid, videoID: aid, resourceType: resourceType, expectedAccount: uid)
        guard rows.allSatisfy({ $0.fav_state == 0 || $0.fav_state == 1 }) else {
          throw ServiceError("无法读取收藏状态")
        }
        try Task.checkCancellation()
        let before = Set(rows.filter { $0.fav_state == 1 }.map(\.id))
        let known = Set(rows.map(\.id))
        let additions = selected.subtracting(original)
        let removals = original.subtracting(selected)
        original = before
        selected = before.union(additions.intersection(known)).subtracting(removals)
        folders = rows
        issue = nil
      } catch {
        if !Task.isCancelled {
          issue = error.localizedDescription
          folders = []
          original = []
          selected = []
        }
      }
    }
    .piliSheet(isPresented: $creating) { FolderEditor(folder: nil, uid: uid) { revision += 1 } }
  }
  private func save() async {
    guard !saving, !loading, !folders.isEmpty else { return }
    TouchFeedback.light()
    guard original != selected else { dismiss(); return }
    saving = true
    defer { saving = false }
    func field(_ ids: Set<Int64>) -> String { ids.sorted().map(String.init).joined(separator: ",") }
    do {
      try await BiliAPI.shared.submit(
        "/x/v3/fav/resource/batch-deal",
        [
          "resources": "\(aid):\(resourceType)",
          "add_media_ids": field(selected.subtracting(original)),
          "del_media_ids": field(original.subtracting(selected)),
        ], expectedAccount: uid)
      dismiss()
    } catch { issue = error.localizedDescription }
  }
}
