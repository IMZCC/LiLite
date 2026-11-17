import SwiftUI

struct FolderEditor: View {
  let folder: Folder?, uid: String
  var saved: () -> Void
  @State private var title: String
  @State private var intro = ""
  @State private var hidden = false
  @State private var cover = ""
  @State private var draftCover: Data?
  @State private var isDefault = false
  @State private var cropping = false
  @State private var ready = false
  @State private var saving = false
  @State private var issue: String?
  @Environment(\.dismiss) var dismiss
  init(folder: Folder?, uid: String, saved: @escaping () -> Void) {
    self.uid = uid
    self.folder = folder
    self.saved = saved
    _title = State(initialValue: folder?.title ?? "")
  }
  struct Info: Decodable { let title: String, intro: String?, attr: Int?, cover: String? }
  var body: some View {
    PiliNavigationStack {
      Form {
        if !isDefault {
          Section("封面") { FolderCoverPicker(cover: $cover, draft: $draftCover, editing: $cropping) }
        }
        TextField("收藏夹名称", text: $title).disabled(isDefault)
          .onChange(of: title) { _, value in
            if !isDefault, value.count > 20 { title = String(value.prefix(20)) }
          }
        if !isDefault {
          TextField("简介", text: $intro, axis: .vertical)
            .onChange(of: intro) { _, value in
              if value.count > 200 { intro = String(value.prefix(200)) }
            }
        }
        Toggle("私密收藏夹", isOn: $hidden)
        if let issue { Text(issue).foregroundStyle(.secondary) }
      }.navigationTitle(folder == nil ? "新建收藏夹" : "编辑收藏夹")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("保存") { Task { await store() } }.disabled(
              !ready || saving || cropping
                || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
    }.task {
      if let folder {
        do {
          let v = try await BiliAPI.shared.read(
            "/x/v3/fav/folder/info", ["media_id": "\(folder.id)"], expectedAccount: uid,
            as: Info.self)
          isDefault = v.attr.map { ($0 & 2) == 0 } ?? false
          title = v.title
          intro = v.intro ?? ""
          cover = v.cover ?? ""
          hidden = ((v.attr ?? 0) & 1) == 1
          ready = true
        } catch { issue = error.localizedDescription }
      } else {
        ready = true
      }
    }.interactiveDismissDisabled(saving)
  }
  private func store() async {
    guard !saving else { return }
    saving = true
    defer { saving = false }
    var fields = ["title": title, "intro": intro, "privacy": hidden ? "1" : "0", "cover": cover]
    if let folder { fields["media_id"] = "\(folder.id)" }
    do {
      if !isDefault, let draftCover {
        cover = try await BiliAPI.shared.folderCover(draftCover, uid: uid)
        fields["cover"] = cover
        self.draftCover = nil
      }
      try await BiliAPI.shared.submit(
        folder == nil ? "/x/v3/fav/folder/add" : "/x/v3/fav/folder/edit", fields,
        expectedAccount: uid)
      saved()
      dismiss()
    } catch { issue = error.localizedDescription }
  }
}
