import SwiftUI

struct ProfileView: View {
  @EnvironmentObject var accounts: AccountContext
  @EnvironmentObject private var indicators: UnreadIndicators
  @Environment(\.dynamicTypeSize) private var textSize
  @AppStorage("badge.messageMode") private var messageMode = 2
  @AppStorage(NavigationLayout.key) private var pageLayout = Data()
  @ObservedObject private var store = ProfileStore.shared
  private var profile: AccountProfile? { accounts.state.active.flatMap { store.profiles[$0] } }
  private var status: String? { accounts.state.active.flatMap { store.issues[$0] } }
  @State private var removal: Identity?
  @State private var destination: ProfileDestination?
  /// The page on screen: `destination` handed on inside an animation, so it slides in (set from
  /// a plain state change, SwiftUI pushed it with no transition at all).
  @State private var shown: ProfileDestination?
  var body: some View {
    PiliNavigationStack {
      let fields = NavigationLayout.read(pageLayout).mineTabs
      List {
        profileHeader
        Section {
          libraryShortcuts
        }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
        // Watch history, when shown, comes first right under the 历史 / 稍后再看 / 收藏 / 离线 shortcuts.
        if fields.contains(.history) { shelf(.history) }
        ForEach(fields.filter { $0 != .history }) { shelf($0) }
        libraryLinks
        if let uid = accounts.state.owner(.history) {
          Section("观看记录") {
            NavigationLink { DeferredPage { HistorySettings(uid: uid).id(uid) } } label: {
              SettingsRowLabel(title: "观看历史设置", symbol: "clock.arrow.circlepath", color: .blue)
            }
          }
        }
        accountList
        Section {
          NavigationLink { DeferredPage { SettingsView() } } label: {
            SettingsRowLabel(title: "设置", symbol: "gearshape.fill")
          }
        }
        if let issue = accounts.issue { Text(issue).foregroundStyle(.secondary) }
      }.listStyle(.insetGrouped).listSectionSpacing(20)
      .animation(.easeOut(duration: 0.25), value: profile?.mid).piliRefreshable { await refresh() }.piliTabRoot(.mine)
      .navigationTitle("我的").navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .topBarTrailing) { ProfileQuickActions() }
      }
      .onChange(of: destination) { _, target in
        guard shown != target else { return }
        withAnimation { shown = target }
      }
      .onChange(of: shown) { _, target in if destination != target { destination = target } }
      .navigationDestination(item: $shown) { target in
        switch target {
        case .space(let uid, let name):
          if let mid = Int64(uid) { CreatorSpace(mid: mid, name: name) }
        case .dynamics(let uid):
          if let mid = Int64(uid) { CreatorDynamics(mid: mid) }
        case .relations(let uid, let fans): RelationsList(uid: uid, fans: fans)
        case .history(let uid): ProfileFullHistory(uid: uid).id(uid)
        case .later(let uid): CloudLibraryView(kind: .later, uid: uid)
        case .favorites(let uid): FavoriteHub(uid: uid).id(uid)
        case .downloads: DownloadsView()
        case .accountUses: AccountRolesPanel()
        case .login: QRLoginView()
        }
      }
      .confirmationDialog(
        "从此设备移除账号？",
        isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
        presenting: removal
      ) { a in
        Button("移除", role: .destructive) { Task { await accounts.forget(a.id) } }
      }
      .task(id: accounts.state.active) {
        guard let uid = accounts.state.active else { return }
        await store.refresh(uid)
      }
    }
  }
  @ViewBuilder private func shelf(_ field: MineSection) -> some View {
    if let uid = field == .history ? accounts.state.owner(.history) : accounts.state.active {
      ProfileShelf(field: field, uid: uid)
        .foregroundStyle(.primary)
        .id("\(field.rawValue):\(uid)")
    }
  }
  private var profileHeader: some View {
    Section {
      if let active = accounts.state.active {
        ProfileOverview(uid: active, profile: profile, stat: store.statistics[active]) { destination = $0 }
        if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
      } else {
        Button { destination = .login } label: { ProfileGuestHeader() }.buttonStyle(.plain)
      }
    }.listRowBackground(Color.clear).listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
  }
  private var libraryShortcuts: some View {
    let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: textSize.isAccessibilitySize ? 2 : 4)
    return LazyVGrid(columns: columns, spacing: 10) {
      Button {
        if let uid = accounts.state.owner(.history) { destination = .history(uid) }
        else if accounts.state.active != nil { destination = .accountUses }
        else { destination = .login }
      } label: { ProfileShortcut(title: "历史", symbol: "clock.arrow.circlepath", color: .blue) }
        .accessibilityLabel("观看历史")
      Button {
        if let uid = accounts.state.active { destination = .later(uid) }
        else { destination = .login }
      } label: { ProfileShortcut(title: "稍后再看", symbol: "text.badge.plus", color: .orange) }
      Button {
        if let uid = accounts.state.active { destination = .favorites(uid) }
        else { destination = .login }
      } label: { ProfileShortcut(title: "收藏", symbol: "star.fill", color: .yellow) }
        .accessibilityLabel("我的收藏")
      Button { destination = .downloads } label: {
        ProfileShortcut(title: "离线", symbol: "arrow.down.circle.fill", color: .purple)
      }.accessibilityLabel("离线缓存")
    }.buttonStyle(.plain)
  }
  /// Only what no other control on this page or the tab bar reaches: the 收藏 shortcut already
  /// holds 追番、追剧、专栏、笔记、话题 and 课堂, the header counts open 关注 and 粉丝 (whose page
  /// carries 分组 and 黑名单), the home bell opens 消息中心 and the ⋯ menu 我的评论.
  @ViewBuilder private var libraryLinks: some View {
    let layout = NavigationLayout.read(pageLayout)
    Section("资料库") {
      NavigationLink { DeferredPage { ListenView() } } label: {
        SettingsRowLabel(title: "听视频", symbol: "headphones", color: .pink)
      }
      if let active = accounts.state.active {
        if !layout.mineTabs.contains(.subscribed) {
          NavigationLink { DeferredPage { Subscriptions(uid: active) } } label: {
            SettingsRowLabel(title: "我的订阅", symbol: "rectangle.stack.fill", color: .orange)
          }
        }
        // The bell lives in the home header; without that tab this is its only way in.
        if !layout.tabs.contains(.home) {
          NavigationLink { DeferredPage { Inbox() } } label: {
            HStack {
              SettingsRowLabel(title: "消息中心", symbol: "bubble.left.and.bubble.right.fill", color: .blue)
              Spacer(minLength: 8)
              if let unread = UnreadTotals.label(indicators.count(for: active, messages: true), mode: messageMode) {
                Text(verbatim: unread).font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.white)
                  .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
                  .background(Color.red, in: Capsule())
              }
            }
          }
        }
      }
    }
    if let active = accounts.state.active {
      Section("账号与隐私") {
        NavigationLink { ProfileEditor(uid: active) { Task { await refresh() } } } label: {
          SettingsRowLabel(title: "账号资料", symbol: "person.crop.circle.fill", color: .blue)
        }
        NavigationLink { DeferredPage { LoginDevices(uid: active) } } label: {
          SettingsRowLabel(title: "登录设备", symbol: "iphone.gen3", color: .indigo)
        }
        NavigationLink { DeferredPage { MobileAuthorization(uid: active) } } label: {
          SettingsRowLabel(title: "移动端授权", symbol: "key.fill", color: .orange)
        }
        NavigationLink { DeferredPage { SpacePrivacy(uid: active) } } label: {
          SettingsRowLabel(title: "空间隐私", symbol: "hand.raised.fill", color: .blue)
        }
        if (profile?.vipStatus ?? 0) > 0 { MemberExperienceButton(uid: active) { Task { await refresh() } } }
        ForEach(AccountLogs.Kind.allCases, id: \.self) { k in
          NavigationLink { DeferredPage { AccountLogs(kind: k, uid: active) } } label: {
            SettingsRowLabel(
              title: k.rawValue,
              symbol: k == .coin ? "bitcoinsign.circle.fill" : k == .exp ? "chart.line.uptrend.xyaxis" : "location.fill",
              color: k == .coin ? .yellow : k == .exp ? .green : .gray)
          }
        }
      }
    } else {
      Section("隐私") {
        NavigationLink { DeferredPage { BlacklistView(uid: "") } } label: {
          SettingsRowLabel(title: "黑名单管理", symbol: "person.crop.circle.badge.xmark", color: .gray)
        }
      }
    }
  }
  private func refresh() async {
    await store.refreshAll(
      uid: accounts.state.active, history: accounts.state.owner(.history),
      fields: NavigationLayout.read(pageLayout).mineTabs)
  }
  @ViewBuilder private var accountList: some View {
    if !accounts.state.accounts.isEmpty {
      Section("切换账号") {
        NavigationLink { DeferredPage { AccountRolesPanel() } } label: {
          SettingsRowLabel(title: "账号用途", symbol: "person.2.fill", color: .indigo)
        }
        ForEach(accounts.state.accounts) { a in
          Button {
            Task { await accounts.select(a.id) }
          } label: {
            HStack(spacing: 12) {
              Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.secondary)
              VStack(alignment: .leading, spacing: 3) {
                Text(a.id == profile.map({ String($0.mid) }) ? (profile?.uname ?? a.label) : a.label)
                  .foregroundStyle(.primary)
                Text("UID " + a.id).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if a.id == accounts.state.active { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
          }.buttonStyle(.borderless).accessibilityAddTraits(a.id == accounts.state.active ? .isSelected : [])
          .swipeActions { Button("移除", role: .destructive) { removal = a } }
        }
        NavigationLink { DeferredPage { QRLoginView() } } label: { SettingsRowLabel(title: "添加账号", symbol: "plus", color: .blue) }
        if accounts.state.active != nil {
          Button { Task { await accounts.select(nil) } } label: {
            SettingsRowLabel(title: "切换到游客模式", symbol: "person.crop.circle.dashed")
          }
        }
      }
    }
  }
}
struct FolderList: View {
  let uid: String
  @State private var editing: Folder?
  @State private var editor = false
  @State private var removing: Folder?
  @State private var revision = 0
  @State private var error: String?
  var body: some View {
    PageList(empty: "暂无收藏夹") { cursor in
      struct Result: Decodable { let list: [Folder]?, has_more: Bool?, count: Int? }
      let page = Int(cursor ?? "1") ?? 1
      let result = try await BiliAPI.shared.read(
        "/x/v3/fav/folder/created/list",
        ["up_mid": uid, "pn": String(page), "ps": "20"], expectedAccount: uid, as: Result.self)
      let rows = result.list ?? []
      return Page(
        items: rows,
        next: !rows.isEmpty
          && (result.has_more ?? result.count.map { page * 20 < $0 } ?? (rows.count == 20))
          ? String(page + 1) : nil)
    } row: { folder in
      PlainRowLink {
        FavoriteFolderScreen(id: folder.id) { revision += 1 }
      } label: {
        MediaRow(
          cover: folder.cover.flatMap(GalleryPicture.source), title: folder.title,
          badge: folder.attr != nil && !folder.isPublic ? "私密" : nil,
          subtitle: "\(folder.media_count ?? 0) 个内容", thumbWidth: 120)
      }
      .swipeActions {
        if folder.attr != nil, !folder.isDefault {
          Button("删除", role: .destructive) { removing = folder }
        }
        Button("编辑") {
          editing = folder
          editor = true
        }
      }
    }.id(revision).navigationTitle("收藏夹")
      .toolbar {
        NavigationLink {
          FavoriteSearchAll(uid: uid)
        } label: {
          Image(systemName: "magnifyingglass").accessibilityLabel("搜索全部收藏夹")
        }
        NavigationLink { CloudOrder(uid: uid) { revision += 1 } } label: {
          Image(systemName: "arrow.up.arrow.down").accessibilityLabel("排序")
        }
        Button {
          editing = nil
          editor = true
        } label: {
          Image(systemName: "folder.badge.plus")
        }
      }
      .piliSheet(isPresented: $editor) { FolderEditor(folder: editing, uid: uid) { revision += 1 } }
      .confirmationDialog(
        "删除整个收藏夹？",
        isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
        presenting: removing
      ) { f in
        Button("删除", role: .destructive) {
          Task {
            do {
              try await BiliAPI.shared.submit(
                "/x/v3/fav/folder/del", ["media_ids": "\(f.id)", "platform": "web"],
                expectedAccount: uid)
              revision += 1
            } catch { self.error = error.localizedDescription }
          }
        }
      }.alert("收藏夹", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
        Button("好") {}
      } message: {
        Text(error ?? "")
      }
  }
}
