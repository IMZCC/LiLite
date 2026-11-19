import SwiftUI

struct LiveAreaCatalog: View {
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    let owner = accounts.state.active, feed = accounts.state.owner(.role(.recommend))
    LiveAreaBrowser(owner: owner, feed: feed).id([owner ?? "", feed ?? ""])
  }
}

private struct LiveAreaBrowser: View {
  let owner: String?, feed: String?
  @State private var groups: [LiveAreaSection] = []
  @State private var selected: String?
  @State private var saved: [LiveAreaTag]?
  @State private var draft: [LiveAreaTag] = []
  @State private var editing = false
  @State private var saving = false
  @State private var loading = true
  @State private var discard = false
  @State private var browseError: String?
  @State private var favError: String?
  @Environment(\.dismiss) private var dismiss
  private var dirty: Bool { editing && draft.map(\.area) != (saved ?? []).map(\.area) }
  private var section: LiveAreaSection? { groups.first { $0.name == selected } ?? groups.first }
  var body: some View {
    Group {
      if editing { editor } else { browser }
    }
    .disabled(saving).navigationTitle("直播分区")
    .navigationBarBackButtonHidden(dirty || saving)
    .toolbar {
      if dirty {
        ToolbarItem(placement: .cancellationAction) { Button("返回") { discard = true }.disabled(saving) }
      }
      if let saved, let owner {
        ToolbarItem(placement: .primaryAction) {
          Button(editing ? "完成" : "编辑常用") {
            if editing { if dirty { Task { await save(owner) } } else { editing = false } }
            else { draft = saved; editing = true }
          }.disabled(saving)
        }
      }
    }.confirmationDialog("离开标签编辑？", isPresented: $discard, titleVisibility: .visible) {
      Button("放弃更改", role: .destructive) { dismiss() }
      Button("继续编辑", role: .cancel) {}
    }.task { await loadGroups() }
    .task { if let owner { await loadFavorites(owner) } }
  }
  /// The original client's area page: favourite tags, then category chips over an icon grid.
  private var browser: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if owner != nil {
          VStack(alignment: .leading, spacing: 12) {
            Text("我的常用").font(.headline)
            if let favError {
              PageFailure(message: favError) { if let owner { Task { await loadFavorites(owner) } } }
            } else if let saved {
              if saved.isEmpty {
                Text("轻点右上角“编辑常用”添加分区").font(.subheadline).foregroundStyle(.secondary)
              } else {
                grid(saved)
              }
            } else {
              ProgressView().frame(maxWidth: .infinity)
            }
          }.padding(.horizontal, 16)
        }
        VStack(alignment: .leading, spacing: 12) {
          Text("全部分区").font(.headline).padding(.horizontal, 16)
          if let browseError {
            PageFailure(message: browseError) { Task { await loadGroups() } }
          } else if groups.isEmpty {
            if loading { PageLoading() } else { Text("暂无分区").foregroundStyle(.secondary).padding(.horizontal, 16) }
          } else {
            ChipBar(items: groups.map(\.name), selection: Binding(get: { section?.name ?? "" }, set: { selected = $0 }), title: { $0 })
            grid(section?.area_list ?? []).padding(.horizontal, 16)
              .id(section?.name).transition(.opacity)
          }
        }
      }
      .padding(.vertical, 12)
      .animation(.easeOut(duration: 0.2), value: section?.name)
    }
    .refreshable { await loadGroups(); if let owner { await loadFavorites(owner) } }
  }
  private func grid(_ tags: [LiveAreaTag]) -> some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 16) {
      ForEach(tags) { tag in
        NavigationLink {
          LiveAreaChannels(parent: tag.parent, initial: String(tag.area), title: tag.parentName.isEmpty ? tag.name : tag.parentName, initialTitle: tag.name)
        } label: {
          VStack(spacing: 6) {
            if let pic = tag.picture, let url = URL(string: pic), url.scheme == "https" {
              SiteThumbnail(url: url) { $0.resizable().scaledToFit() } placeholder: {
                Circle().fill(.quaternary)
              }.frame(width: 44, height: 44)
            } else {
              Image(systemName: "square.grid.2x2.fill").font(.title2).foregroundStyle(.tint)
                .frame(width: 44, height: 44)
            }
            Text(tag.name).font(.caption).lineLimit(1)
          }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain)
      }
    }
  }
  private var editor: some View {
    List {
      if let owner {
        Section("我的常用标签") {
          if let favError { Text(favError); Button("重新载入标签") { Task { await loadFavorites(owner) } }.disabled(saving) }
          if let saved {
            let rows = editing ? draft : saved
            if rows.isEmpty { Text(editing ? "从下方分区添加标签" : "还没有常用标签").foregroundStyle(.secondary) }
            ForEach(rows) { tag in
              if editing { label(tag) } else { destination(tag) }
            }.onDelete(perform: editing ? { draft.remove(atOffsets: $0) } : nil)
             .onMove(perform: editing ? { draft.move(fromOffsets: $0, toOffset: $1) } : nil)
          } else if favError == nil { ProgressView() }
        }
      }
      Section("全部分区") {
        if let browseError { Text(browseError); Button("重试") { Task { await loadGroups() } } }
        if loading && groups.isEmpty { ProgressView() }
        if !groups.isEmpty {
          Picker("分区", selection: Binding(get: { section?.name ?? "" }, set: { selected = $0 })) {
            ForEach(groups) { g in Text(g.name).tag(g.name) }
          }
          ForEach(section?.area_list ?? []) { tag in
            if editing {
              Button { toggle(tag) } label: {
                HStack { label(tag); Spacer(); Image(systemName: draft.contains { $0.area == tag.area } ? "checkmark.circle.fill" : "plus.circle") }
              }.disabled(tag.area == 0 || saving)
            } else { destination(tag) }
          }
        } else if !loading && browseError == nil { Text("暂无分区") }
      }
    }.environment(\.editMode, .constant(editing ? .active : .inactive))
  }

  private func label(_ tag: LiveAreaTag) -> some View {
    HStack {
      if let pic = tag.picture, let url = URL(string: pic), url.scheme == "https" {
        SiteThumbnail(url: url) { image in image.resizable().scaledToFit() } placeholder: { Color.clear }
          .frame(width: 32, height: 32).accessibilityHidden(true)
      }
      Text(tag.name)
    }
  }
  private func destination(_ tag: LiveAreaTag) -> some View {
    NavigationLink {
      LiveAreaChannels(parent: tag.parent, initial: String(tag.area), title: tag.parentName.isEmpty ? tag.name : tag.parentName, initialTitle: tag.name)
    } label: { label(tag) }
  }
  private func toggle(_ tag: LiveAreaTag) {
    guard tag.area > 0, !saving else { return }
    if draft.contains(where: { $0.area == tag.area }) { draft.removeAll { $0.area == tag.area } }
    else { draft.append(tag) }
  }
  @MainActor private func loadGroups() async {
    loading = true; defer { loading = false }
    do {
      let result = try await BiliAPI.shared.liveAreaSections(owner: feed)
      try Task.checkCancellation()
      groups = result; browseError = nil
    } catch { if !Task.isCancelled { browseError = error.localizedDescription } }
  }
  @MainActor private func loadFavorites(_ owner: String) async {
    do {
      let result = try await BiliAPI.shared.liveFavoriteTags(owner)
      try Task.checkCancellation()
      saved = result; draft = result; editing = false; favError = nil
    } catch { if !Task.isCancelled { favError = error.localizedDescription } }
  }
  @MainActor private func save(_ owner: String) async {
    guard !saving, let saved else { return }
    saving = true; defer { saving = false }
    do {
      try await BiliAPI.shared.saveLiveTags(draft.map(\.area), replacing: saved.map(\.area), owner: owner)
      try Task.checkCancellation()
      self.saved = draft; editing = false; favError = nil
    } catch { if !Task.isCancelled { favError = error.localizedDescription } }
  }
}

struct LiveAreaChannels: View {
  let parent: Int, initial: String, title: String, initialTitle: String
  @EnvironmentObject private var accounts: AccountContext
  @State private var children: [LiveAreaTag] = []
  @State private var subError: String?
  @State private var reload = 0
  private var feed: String? { accounts.state.owner(.role(.recommend)) }
  @State private var selection: String?
  var body: some View {
    VStack(spacing: 0) {
      let extra = initial != "0" && !children.contains(where: { String($0.area) == initial })
      let keys = ["0"] + (extra ? [initial] : []) + children.filter { $0.area != 0 }.map { String($0.area) }
      ChipBar(
        items: keys, selection: Binding(get: { selection ?? initial }, set: { selection = $0 }),
        title: { key in
          key == "0" ? "全部" : key == initial && extra ? initialTitle
            : children.first { String($0.area) == key }?.name ?? key
        }
      ).padding(.vertical, 6)
      if let subError { Button("重试载入子分区") { reload += 1 }.accessibilityHint(subError) }
      LiveDirectory(area: parent, child: selection ?? initial, title: title).id(selection ?? initial)
    }.navigationTitle(title)
    .toolbar {
      NavigationLink { DeferredPage { LiveSearchView() } } label: { Image(systemName: "magnifyingglass").accessibilityLabel("直播搜索") }
    }
      .task(id: "\(parent):\(feed ?? ""):\(reload)") {
        let owner = feed
        children = []; subError = nil
        do {
          let result = try await BiliAPI.shared.liveSubareas(parent: parent, owner: owner)
          try Task.checkCancellation()
          if feed == owner { children = result }
        } catch { if !Task.isCancelled && feed == owner { subError = error.localizedDescription } }
      }
  }
}
