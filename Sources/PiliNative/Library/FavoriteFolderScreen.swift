import SwiftUI

struct FavoriteFolderInfo: Decodable {
  struct Upper: Decodable { let mid: Int64?, name: String?, face: String? }
  struct Count: Decodable { let play: Int64?, collect: Int64? }
  let id: Int64, title: String, mid: Int64?, upper: Upper?, attr: Int?, cover: String?,
    intro: String?
  let fav_state: Int?, media_count: Int?, cnt_info: Count?
  var folder: Folder {
    Folder(
      id: id, title: title, media_count: media_count, fav_state: fav_state, attr: attr,
      cover: cover, intro: intro)
  }
  var author: Int64? { mid ?? upper?.mid }
}
struct FavoriteFolderScreen: View {
  let id: Int64
  var changed: () -> Void = {}
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    FolderScreenContent(id: id, viewer: accounts.state.active ?? "", changed: changed)
      .id("\(id):\(accounts.state.active ?? "")")
  }
}
private struct FolderScreenContent: View {
  let id: Int64, viewer: String, changed: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var info: FavoriteFolderInfo?
  @State private var loadError: String?
  @State private var actionError: String?
  @State private var revision = 0
  @State private var editing = false
  @State private var sharing = false
  @State private var busy = false
  @State private var confirmation: Action?
  @State private var coverPreview: URL?
  @State private var creator: CreatorTarget?
  private struct CreatorTarget: Hashable { let mid: Int64, name: String }
  private enum Action: String, Identifiable {
    case clean = "清除失效内容"
    case delete = "删除收藏夹"
    case unsubscribe = "取消收藏"
    var id: Self { self }
  }
  var body: some View {
    Group {
      if let info {
        let owned = info.author.map(String.init) == viewer
        CloudLibraryView(
          kind: .favorites(info.folder), uid: viewer, allowChanges: owned,
          heading: AnyView(summary(info))
        )
        .id(revision)
        .toolbar {
          Menu {
            if info.folder.isPublic,
              let link = URL(string: "https://www.bilibili.com/medialist/detail/ml\(id)")
            {
              ShareLink(item: link)
              if !viewer.isEmpty { Button("分享至动态") { sharing = true } }
            }
            if owned {
              Button("编辑信息") { editing = true }
              Button("清除失效内容") { confirmation = .clean }
              if info.attr != nil, !info.folder.isDefault {
                Button("删除收藏夹", role: .destructive) { confirmation = .delete }
              }
            } else if !viewer.isEmpty, let state = info.fav_state {
              Button(state == 1 ? "取消收藏" : "收藏此收藏夹") {
                if state == 1 { confirmation = .unsubscribe } else { Task { await subscribe() } }
              }
            }
          } label: {
            Image(systemName: "ellipsis.circle").accessibilityLabel("收藏夹选项")
          }.disabled(busy)
        }
        .piliSheet(isPresented: $editing) {
          FolderEditor(folder: info.folder, uid: viewer) { reload() }
        }
        .piliSheet(isPresented: $sharing) {
          DynamicComposer(resource: .init(id: id, type: 4300, title: info.title)) {}
        }
        .navigationDestination(item: $coverPreview) { NativeGallery([.init($0)]) }
        .navigationDestination(item: $creator) { CreatorSpace(mid: $0.mid, name: $0.name) }
      } else if let loadError {
        PageFailure(message: loadError) { revision += 1 }
      } else {
        PageLoading()
      }
    }
    .confirmationDialog(
      confirmation?.rawValue ?? "收藏夹",
      isPresented: Binding(
        get: { confirmation != nil },
        set: { if !$0 { confirmation = nil } }), presenting: confirmation
    ) { intent in
      Button(intent.rawValue, role: .destructive) { Task { await perform(intent) } }
    }
    .alert(
      "收藏夹",
      isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    ) {
      Button("好") {}
    } message: {
      Text(actionError ?? "")
    }
    .task(id: revision) {
      do {
        let result = try await BiliAPI.shared.read(
          "/x/v3/fav/folder/info", ["media_id": String(id)], expectedAccount: viewer,
          as: FavoriteFolderInfo.self)
        try Task.checkCancellation()
        guard result.id == id else { throw ServiceError("收藏夹已变更") }
        info = result
        loadError = nil
      } catch {
        if !Task.isCancelled {
          info = nil
          loadError = error.localizedDescription
        }
      }
    }
  }
  /// A list row may hold only one navigation target; extra links add stray chevrons and squeeze
  /// the layout. The cover and the creator therefore push through state-driven destinations.
  /// The original client's folder header: cover on the left, then title, creator and counts,
  /// with the introduction underneath.
  private func summary(_ info: FavoriteFolderInfo) -> some View {
    VStack(alignment: .leading, spacing: 10) {
    HStack(alignment: .top, spacing: 14) {
      if let cover = info.cover.flatMap(GalleryPicture.source) {
        Button { coverPreview = cover } label: {
          SiteThumbnail(url: cover) {
            $0.resizable().scaledToFill()
          } placeholder: {
            Color.clear
          }
          .frame(width: 140, height: 88).background(.quaternary).clipped()
          .clipShape(RoundedRectangle(cornerRadius: NativeGlass.cardRadius, style: .continuous))
        }.buttonStyle(.plain).accessibilityLabel("查看封面")
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(info.title).font(.headline).lineLimit(2)
        if let mid = info.author {
          Button {
            creator = .init(mid: mid, name: info.upper?.name ?? "用户空间")
          } label: {
            HStack(spacing: 6) {
              SiteThumbnail(url: info.upper?.face.flatMap(httpsURL)) { $0.resizable().scaledToFill() } placeholder: {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.quaternary)
              }
              .frame(width: 20, height: 20).clipShape(Circle())
              Text(info.upper?.name ?? "创建者").font(.subheadline).foregroundStyle(.secondary)
            }
          }.buttonStyle(.plain)
        }
        Spacer(minLength: 0)
        Text(
          [
            info.attr == nil ? nil : info.folder.isPublic ? "公开" : "私密",
            info.media_count.map { "\($0) 项" },
            info.cnt_info?.play.map { "\($0.formatted(.number.notation(.compactName))) 播放" },
            info.cnt_info?.collect.map { "\($0.formatted(.number.notation(.compactName))) 收藏" },
          ].compactMap { $0 }.joined(separator: " · ")
        )
        .font(.footnote).foregroundStyle(.secondary)
      }
      .frame(height: 88, alignment: .topLeading)
    }
    .fixedSize(horizontal: false, vertical: true)
      if let intro = info.intro, !intro.isEmpty {
        Text(intro).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 4)
    .listRowSeparator(.hidden)
  }
  private func reload() {
    changed()
    revision += 1
  }
  private func subscribe() async {
    guard !busy, !viewer.isEmpty, info?.fav_state != 1 else { return }
    busy = true
    defer { busy = false }
    do {
      try await BiliAPI.shared.submit(
        "/x/v3/fav/folder/fav", ["media_id": String(id)], expectedAccount: viewer)
      reload()
    } catch { actionError = error.localizedDescription }
  }
  private func perform(_ action: Action) async {
    guard !busy, !viewer.isEmpty, let info else { return }
    busy = true
    defer { busy = false }
    do {
      switch action {
      case .unsubscribe:
        guard info.author.map(String.init) != viewer, info.fav_state == 1 else { return }
        try await BiliAPI.shared.submit(
          "/x/v3/fav/folder/unfav", ["media_id": String(id)], expectedAccount: viewer)
      case .clean:
        guard info.author.map(String.init) == viewer else { return }
        try await BiliAPI.shared.submit(
          "/x/v3/fav/resource/clean", ["media_id": String(id), "platform": "web"],
          expectedAccount: viewer)
      case .delete:
        guard info.author.map(String.init) == viewer, info.attr != nil, !info.folder.isDefault
        else { return }
        try await BiliAPI.shared.submit(
          "/x/v3/fav/folder/del", ["media_ids": String(id), "platform": "web"],
          expectedAccount: viewer)
        changed()
        dismiss()
        return
      }
      reload()
    } catch { actionError = error.localizedDescription }
  }
}
