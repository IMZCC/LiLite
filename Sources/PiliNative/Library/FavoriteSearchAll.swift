import SwiftUI

struct FavoriteSearchAll: View {
  let uid: String
  @State private var text = ""
  @State private var term = ""
  @State private var order = FavoriteSort.mtime
  @State private var rows = [String: FavoriteMedia]()
  @State private var selection = Set<String>()
  @State private var displayOrder: [String] = []
  @State private var selecting = false
  @State private var organize = false
  @State private var rev = 0
  @State private var defaultFolder: Int64?
  @State private var issue: String?
  @State private var loading = true
  var body: some View {
    Group {
      if let issue {
        VStack {
          Text(issue)
          Button("重试") { rev += 1 }
        }
      } else if loading {
        ProgressView()
      } else if let base = defaultFolder, !term.isEmpty {
        PageList(empty: "没有找到收藏内容") { cursor in
          let page = try await BiliAPI.shared.favoriteMedia(
            base, page: Int(cursor ?? "1") ?? 1, term: term, order: order, user: uid, across: true)
          try Task.checkCancellation()
          if cursor == nil { rows = [:]; displayOrder = [] }
          for item in page.items {
            if rows[item.id] == nil { displayOrder.append(item.id) }; rows[item.id] = item
          }
          return page
        } row: { item in
          if selecting {
            Button {
              if !selection.insert(item.id).inserted { selection.remove(item.id) }
            } label: {
              Label(
                item.displayName,
                systemImage: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
            }
          } else {
            FavoriteMediaLink(media: item).contextMenu {
              ContextLink("管理收藏夹", systemImage: "folder") {
                PickFolder(uid: uid, aid: item.number, resourceType: item.type)
              }
              Button("整理此项") {
                selection = [item.id]
                organize = true
              }
            }
          }
        }.id("\(term):\(order.rawValue):\(rev)")
      } else {
        ContentUnavailableView(
          defaultFolder == nil ? "暂无收藏夹" : "输入关键词搜索全部收藏夹", systemImage: "magnifyingglass")
      }
    }.contextPushHost().navigationTitle("搜索全部收藏夹").searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "标题或关键词")
      .onSubmit(of: .search) {
        term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        selection = []
        selecting = false
      }
      .onChange(of: text) { _, v in
        if v.isEmpty {
          term = ""
          selection = []
          selecting = false
        }
      }
      .onChange(of: order) { _, _ in
        selection = []
        selecting = false
      }
      .toolbar {
        Menu {
          Picker("排序", selection: $order) {
            ForEach(FavoriteSort.allCases, id: \.self) { Text($0.label).tag($0) }
          }
          Button(selecting ? "结束选择" : "选择内容") {
            selecting.toggle()
            selection = []
          }
          if selecting {
            Button("全选已加载内容") { selection = Set(rows.keys) }
            Button("整理所选 \(selection.count) 项") { organize = true }.disabled(selection.isEmpty)
          }
        } label: {
          Image(systemName: "slider.horizontal.3").accessibilityLabel("搜索结果选项")
        }
      }.piliSheet(isPresented: $organize) {
        FavoriteSearchOrganizer(uid: uid, media: displayOrder.filter(selection.contains).compactMap { rows[$0] }) {
          selecting = false
          selection = []
          rev += 1
        }
      }.task(id: "\(uid):\(rev)") {
        loading = true
        issue = nil
        defer { if !Task.isCancelled { loading = false } }
        do {
          let list = try await BiliAPI.shared.folders(uid: uid, expectedAccount: uid)
          try Task.checkCancellation()
          defaultFolder = list.first(where: { $0.isDefault })?.id ?? list.first?.id
        } catch { if !Task.isCancelled { issue = error.localizedDescription } }
      }
  }
}

private struct FavoriteSearchOrganizer: View {
  enum Operation: String, CaseIterable {
    case copy = "复制"
    case move = "移动"
    case remove = "移除"
  }
  let uid: String, media: [FavoriteMedia], changed: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var folders = [Folder]()
  @State private var members = [Int64: Set<String>]()
  @State private var source: Int64?
  @State private var destination: Int64?
  @State private var action = Operation.copy
  @State private var confirmation = false
  @State private var busy = true
  @State private var ready = false
  @State private var failure: String?
  @State private var retry = 0
  private var resources: Set<String> {
    action == .copy ? Set(media.map(\.id)) : source.flatMap { members[$0] } ?? []
  }
  private var allowed: Bool {
    guard ready, !busy, !resources.isEmpty else { return false }
    if action == .remove { return source != nil }
    return destination != nil && (action == .copy || source != destination)
  }
  var body: some View {
    PiliNavigationStack {
      Form {
        Picker("操作", selection: $action) {
          ForEach(Operation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented)
        if action != .copy {
          Picker("来源收藏夹", selection: $source) {
            Text("请选择").tag(nil as Int64?)
            ForEach(folders.filter { members[$0.id]?.isEmpty == false }) { f in
              Text(f.title + "（\(members[f.id]?.count ?? 0) 项）").tag(Optional(f.id))
            }
          }
        }
        if action != .remove {
          Picker("目标收藏夹", selection: $destination) {
            Text("请选择").tag(nil as Int64?)
            ForEach(folders.filter { action == .copy || $0.id != source }) {
              Text($0.title).tag(Optional($0.id))
            }
          }
        }
        Text("\(action.rawValue) \(resources.count) 项")
        if busy { ProgressView() }
        if let failure {
          Text(failure)
          if !ready { Button("重试") { retry += 1 } }
        }
      }.navigationTitle("整理收藏").disabled(busy).interactiveDismissDisabled(busy && ready)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("关闭") { dismiss() }.disabled(busy && ready)
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("确认") { confirmation = true }.disabled(!allowed)
          }
        }
        .task(id: retry) { await load() }
        .onChange(of: source) { _, to in
          if action == .move && to == destination { destination = nil }
        }
        .confirmationDialog(
          "\(action.rawValue)这 \(resources.count) 项收藏？", isPresented: $confirmation
        ) {
          Button(action.rawValue, role: action == .remove ? .destructive : nil) {
            Task { await save() }
          }
        }
    }
  }
  private func load() async {
    busy = true
    ready = false
    failure = nil
    defer { busy = false }
    do {
      let available = try await BiliAPI.shared.folders(uid: uid, expectedAccount: uid)
      var groups = [Int64: Set<String>]()
      for item in media {
        try Task.checkCancellation()
        let list = try await BiliAPI.shared.folders(
          uid: uid, videoID: item.number, resourceType: item.type, expectedAccount: uid)
        guard list.allSatisfy({ $0.fav_state == 0 || $0.fav_state == 1 }) else {
          throw ServiceError("无法读取来源收藏夹")
        }
        for folder in list where folder.fav_state == 1 {
          groups[folder.id, default: []].insert(item.id)
        }
      }
      try Task.checkCancellation()
      folders = available
      members = groups
      ready = true
      if groups.count == 1 { source = groups.keys.first }
    } catch { if !Task.isCancelled { failure = error.localizedDescription } }
  }
  private func save() async {
    guard allowed else { return }
    busy = true
    defer { busy = false }
    do {
      let ids = try LibraryCheckedOrder.items(display: media.map(\.id), selected: resources,
        movingFavorite: action != .remove).joined(separator: ",")
      if action == .copy, let destination {
        try await BiliAPI.shared.submit(
          "/x/v3/fav/resource/batch-deal",
          ["resources": ids, "add_media_ids": String(destination), "del_media_ids": ""],
          expectedAccount: uid)
      } else if let source, let folder = folders.first(where: { $0.id == source }) {
        let kind = CloudLibraryKind.favorites(folder)
        if action == .move, let destination {
          try await kind.transfer(ids, to: destination, copy: false, uid: uid)
        } else if action == .remove {
          try await kind.remove(ids, uid: uid)
        } else {
          return
        }
      } else {
        return
      }
      changed()
      dismiss()
    } catch { failure = error.localizedDescription }
  }
}
