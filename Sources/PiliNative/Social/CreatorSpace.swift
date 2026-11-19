import SwiftUI

/// A creator's space, laid out like the official app and the original client's MemberPage: the
/// banner runs under the navigation bar, the avatar sits over its edge with the counts and the
/// follow button beside it, then name, badges, verification, bio and tags, and the section tabs
/// pin under the bar. Sections page sideways like the original's TabBarView (see `page`).
struct CreatorSpace: View {
  let mid: Int64, name: String
  @EnvironmentObject var accounts: AccountContext
  @AppStorage(CreatorSection.preference) private var defaultSection = 0
  @AppStorage("creator.shop") private var showShop = false
  @AppStorage("social.hideGoods") private var hideGoods = false
  @AppStorage("social.dynamicRegex") private var dynamicPattern = ""
  @Environment(\.colorScheme) private var scheme
  @State private var reservations: [CreatorSpaceRecord.Reservation] = []
  @State private var space: CreatorSpaceRecord?
  @State private var selectedTab: String?
  @State private var loadingError: String?
  @State private var revision = 0
  @State private var showPerson = false
  private struct LoadKey: Equatable { let mid: Int64, owner: String?, revision: Int }
  @State private var loadedKey: LoadKey?
  @State private var contentKey: LoadKey?
  @State private var loadToken = UUID()
  @State private var relation: CreatorRelation?
  @State private var confirmUnfollow = false
  @State private var confirmBlock = false
  @State private var confirmRemoveFan = false
  @State private var reviewedOwner: String?
  @State private var removedFan = false
  @State private var issue: String?
  @State private var busy = false
  @State private var route: Route?
  @State private var topInset: CGFloat = 100
  @State private var headerHeight: CGFloat = 320
  @State private var collapsed = false
  // The section pager: one vertical page per tab, side by side.
  @State private var pageSize = CGSize(width: 400, height: 800)
  @State private var motion = PagerIndicatorMotion()
  @State private var paged: String?
  @State private var visited = Set<String>()
  @State private var scrollers = SpaceScrollers()
  @State private var swiping = false
  // Section rows, kept while switching tabs.
  @State private var dynamics = InlinePager<DynamicEntry>()
  @State private var uploads = InlinePager<Video>()
  @State private var bangumi = InlinePager<CreatorSpaceRecord.Media>()
  @State private var folders = SpaceFolders()
  @State private var category: String?
  @State private var order = "pubdate"
  @State private var playing: SpacePlay?
  private enum Route: Hashable {
    case library, relations(fans: Bool), report(String), shared(String, also: Bool), chat
    case groups(String), account, edit, reservations, search, live(Int64)
  }
  private struct SpacePlay: Identifiable {
    let id = UUID()
    let scope: CreatorArchiveScope
  }
  private var header: CreatorSpaceRecord.Person? { space?.person }
  private var tabs: [CreatorSpaceRecord.Tab] { space?.sections(shop: showShop) ?? [] }
  private var selected: CreatorSpaceRecord.Tab? {
    tabs.first { $0.param == selectedTab }
      ?? tabs.first { $0.param == space?.preferred(defaultSection, in: tabs) }
  }
  private var barSolid: Bool { collapsed || space == nil }
  /// A section page runs from under the navigation bar to the bottom of the screen.
  private var pageHeight: CGFloat { max(100, pageSize.height) }

  var body: some View {
    Group {
      if let space {
        page(space)
      } else if let loadingError {
        PageFailure(message: loadingError) { revision += 1 }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        PageLoading().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(Color(uiColor: .systemBackground))
    .navigationTitle(header?.name ?? name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
    .toolbarBackground(barSolid ? .visible : .hidden, for: .navigationBar)
    .toolbar {
      ToolbarItem(placement: .principal) {
        Text(header?.name ?? name).font(.headline).lineLimit(1)
          .opacity(barSolid ? 1 : 0).animation(.easeOut(duration: 0.15), value: barSolid)
      }
      ToolbarItemGroup(placement: .topBarTrailing) {
        if !reservations.isEmpty {
          Button { route = .reservations } label: { Image(systemName: "calendar.badge.clock") }
            .accessibilityLabel("预约")
        }
        Button { route = .search } label: { Image(systemName: "magnifyingglass") }
          .accessibilityLabel("搜索空间")
        moreMenu
      }
    }
    .navigationDestination(item: $route) { destination($0) }
    .momentNavigation()
    .piliSheet(isPresented: $showPerson) {
      if let person = header {
        PiliNavigationStack {
          CreatorIdentityView(person: person, mid: mid, medals: space?.medalsVisible == true,
            ownsMedal: space?.ownsMedal == true, header: space?.headerDetails)
            .toolbar { Button("完成") { showPerson = false } }
        }
      }
    }
    .piliFullScreenCover(item: $playing) { play in
      LibraryPlaylist(
        kind: .creator(play.scope, nil), uid: play.scope.owners.main, query: "", order: .mtime,
        viewed: 0, ascending: false, start: PlaylistStart(), allowChanges: false)
    }
    .onChange(of: defaultSection) { _, _ in selectedTab = nil }
    .task(id: LoadKey(mid: mid, owner: accounts.state.active, revision: revision)) { await loadSpace() }
    .task(id: sectionKey) { prepareSections() }
    .confirmationDialog("将这位用户移出粉丝列表？", isPresented: $confirmRemoveFan) {
      if let uid = reviewedOwner, accounts.state.active == uid {
        Button("移除", role: .destructive) { Task { await act(uid, 7) } }
      }
    }
    .confirmationDialog("取消关注这位 UP 主？", isPresented: $confirmUnfollow) {
      if let uid = reviewedOwner, accounts.state.active == uid {
        Button("取消关注", role: .destructive) { Task { await act(uid, 2) } }
      }
    }
    .confirmationDialog(
      relation?.attribute == 128 ? "将此用户移出黑名单？" : "将此用户加入黑名单？", isPresented: $confirmBlock
    ) {
      if let uid = reviewedOwner, accounts.state.active == uid {
        let code = relation?.attribute == 128 ? 6 : 5
        Button("确认", role: .destructive) { Task { await act(uid, code) } }
      }
    }
    .alert("关注", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
      Button("好") {}
    } message: {
      Text(issue ?? "")
    }
  }

  // MARK: Page

  /// The original's TabBarView under a NestedScrollView: every section is its own vertical page
  /// in a native horizontal pager, so a swipe follows the finger with the neighbour already laid
  /// out (and loaded). Each page carries the header and the pinned tabs; those copies are held in
  /// place against the swipe, and pages are aligned before they show, so they read as one header
  /// standing still while only the rows slide.
  private func page(_ space: CreatorSpaceRecord) -> some View {
    // Sized from the screen, not from the pager (a horizontal pager's height follows its pages).
    // The pager starts under the bar and runs to the bottom edge of the screen.
    GeometryReader { g in
      let height = g.size.height + g.safeAreaInsets.bottom
      pager(space)
        .frame(width: g.size.width, height: height, alignment: .top)
        .ignoresSafeArea(edges: .bottom)
        .onChange(of: [g.size.width, height, g.safeAreaInsets.top], initial: true) { _, v in
          if v[0] > 0, v[1] > 0 { pageSize = CGSize(width: v[0], height: v[1]) }
          if v[2] > 0 { topInset = v[2] }
        }
    }
  }
  private func pager(_ space: CreatorSpaceRecord) -> some View {
    let list = tabs
    let current = selected?.param
    return ScrollView(.horizontal) {
      HStack(spacing: 0) {
        if list.isEmpty {
          sectionPage(nil, space, index: 0).frame(width: pageSize.width, height: pageHeight)
        }
        ForEach(Array(list.enumerated()), id: \.element.param) { index, tab in
          sectionPage(tab, space, index: index)
            .frame(width: pageSize.width, height: pageHeight)
            .id(tab.param)
        }
      }
      // Pages start right under the bar: a page shorter than the pager's view was centred in it,
      // leaving a gap above the pinned tabs.
      .frame(height: pageHeight, alignment: .top)
      .scrollTargetLayout()
    }
    .scrollIndicators(.hidden)
    .scrollTargetBehavior(.paging)
    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    // The pager is the scroll view next to the bar: without this its soft edge washed the banner
    // out behind the bar.
    .piliScrollEdgeEffectHidden(!collapsed, for: .top)
    // Pages sit below the bar; the banner draws above them, so neither scroller may clip it.
    .scrollClipDisabled()
    .scrollPosition(id: $paged)
    .piliOnScrollGeometryChange(for: CGFloat.self) { g in
      g.containerSize.width > 0 ? g.contentOffset.x / g.containerSize.width : 0
    } action: { _, value in
      motion.update(min(max(0, value), CGFloat(max(0, list.count - 1))))
    }
    .piliOnScrollPhaseChange { old, phase, _ in
      if phase == .interacting { swiping = true }
      // Line the neighbours up with this page before they slide into view.
      if old == .idle && phase != .idle { alignPages() }
      if phase == .idle {
        // Only a swipe changes the section. The pager may report another page while it is laid
        // out or moved in code; put it back on the selected one.
        if swiping, let value = paged, value != selected?.param {
          settle(on: value)
        } else if !swiping, let current = selected?.param, paged != current {
          paged = current
        }
        swiping = false
      }
    }
    .onChange(of: current, initial: true) { _, value in
      guard let value else { return }
      visited.insert(value)
      guard paged != value else { return }
      if paged == nil {
        paged = value
      } else {
        alignPages()
        withAnimation(.smooth(duration: 0.32)) { paged = value }
      }
    }
    // On the first section a swipe to the right anywhere goes Back; elsewhere only the edge does,
    // and the rest of the width pages between sections.
    .background { LeadingEdgeNavigation(fullWidth: current == list.first?.param).frame(width: 0, height: 0) }
  }

  @ViewBuilder private func sectionPage(_ tab: CreatorSpaceRecord.Tab?, _ space: CreatorSpaceRecord, index: Int)
    -> some View
  {
    let key = tab?.param ?? ""
    let active = tab == nil || key == selected?.param
    let near = abs(index - (tabs.firstIndex { $0.param == selected?.param } ?? 0)) <= 1
    if active || near || visited.contains(key) {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
          profile(space)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0 > 0 { headerHeight = $0 } }
            .modifier(HeldInPlace(index: index, motion: motion, width: pageSize.width))
          if let tab {
            Section {
              sectionBody(tab, space)
            } header: {
              if tabs.count > 1 {
                tabBar(tab).modifier(HeldInPlace(index: index, motion: motion, width: pageSize.width))
              }
            }
          } else {
            ContentUnavailableView("暂无公开栏目", systemImage: "person.crop.rectangle").padding(.top, 40)
          }
        }
        // Every page can scroll far enough to pin its tabs, so pages can always be aligned.
        .frame(minHeight: pageHeight + headerHeight, alignment: .top)
        .background {
          ScrollerProbe { scroller in
            scrollers.register(key, scroller)
            if !active { alignPages() }
          }
        }
      }
      // The pager lays its pages out below the bar. The banner reaches up behind the bar by
      // drawing past the page's top edge, so the page clips to its own width (other pages' header
      // copies stay hidden) and to the bar's height above it, instead of to its frame.
      .scrollClipDisabled()
      .clipShape(RaisedClip(raise: topInset))
      .piliScrollEdgeEffectHidden(!collapsed, for: .top)
      .piliOnScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
        guard key == (selected?.param ?? "") else { return }
        let fold = y > 110
        if fold != collapsed { collapsed = fold }
      }
      .piliRefreshable { await refresh(key) }
      .allowsHitTesting(active)
      .accessibilityHidden(!active)
    } else {
      Color.clear
    }
  }

  /// Puts the other pages where the header of the page on screen is: at the same offset while the
  /// header shows, or at least with their tabs pinned once it has folded away.
  private func alignPages() {
    guard let active = selected?.param, let y = scrollers.offset(active) else { return }
    for tab in tabs where tab.param != active {
      guard let other = scrollers.offset(tab.param) else { continue }
      let want = y < headerHeight ? y : max(other, headerHeight)
      if abs(want - other) > 0.5 { scrollers.setOffset(tab.param, want) }
    }
  }
  private func settle(on value: String) {
    selectedTab = value
    visited.insert(value)
    if let y = scrollers.offset(value) { collapsed = y > 110 }
  }

  private func tabBar(_ tab: CreatorSpaceRecord.Tab) -> some View {
    UnderlineTabBar(
      items: tabs.map(\.param),
      selection: Binding(get: { tab.param }, set: { selectedTab = $0 }),
      title: { param in
        tabs.first { $0.param == param }?.title ?? CreatorSection(param: param)?.label ?? param
      },
      fill: tabs.count <= 5, motion: motion)
    .background(Color(uiColor: .systemBackground))
    .overlay(alignment: .bottom) { Divider() }
  }

  // MARK: Header

  @ViewBuilder private func profile(_ space: CreatorSpaceRecord) -> some View {
    let p = space.person
    VStack(alignment: .leading, spacing: 0) {
      banner(space.headerDetails)
      HStack(alignment: .top, spacing: 12) {
        avatar(p, space).padding(.top, -34)
        VStack(spacing: 10) {
          stats(p)
          actions(p)
        }
        .padding(.top, 10)
      }
      .padding(.horizontal, 14)
      identity(p, space.headerDetails).padding(.horizontal, 16).padding(.top, 10)
      if let loadingError {
        HStack {
          Text(loadingError).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          Spacer()
          Button("重试") { revision += 1 }.font(.caption.weight(.semibold))
        }.padding(.horizontal, 16).padding(.top, 8)
      }
      Color.clear.frame(height: 12)
    }
  }

  /// The banner reaches up to the top of the screen behind the navigation bar, and so also
  /// stretches when the page is pulled down.
  private func banner(_ h: CreatorSpaceRecord.HeaderDetails) -> some View {
    let url = (scheme == .dark ? h.night ?? h.day : h.day).flatMap(httpsURL)
    let top = topInset
    return GeometryReader { g in
      let reach = max(0, g.frame(in: .global).minY)
      SiteThumbnail(url: url) { $0.resizable().scaledToFill() } placeholder: {
        LinearGradient(
          colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.08)],
          startPoint: .topLeading, endPoint: .bottomTrailing)
      }
      .frame(width: g.size.width, height: g.size.height + reach)
      .clipped()
      .overlay(alignment: .top) {
        // Keeps the status bar and the glass buttons readable on a bright banner.
        LinearGradient(colors: [.black.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)
          .frame(height: min(reach, top))
      }
      .offset(y: -reach)
    }
    .frame(height: 80)
    .accessibilityHidden(true)
  }

  private func avatar(_ p: CreatorSpaceRecord.Person?, _ space: CreatorSpaceRecord) -> some View {
    let author = ReplyAuthor(
      name: p?.name ?? name, avatar: p?.face,
      badge: p?.verifyType.map { .init(type: $0, desc: p?.verifyText) },
      pendant: p?.pendant, vipStatus: p?.vipStatus ?? 0, vipType: p?.vipType ?? 0, card: nil)
    return Button { showPerson = true } label: {
      ReplyAvatar(member: author, size: 76)
        .background { Circle().fill(Color(uiColor: .systemBackground)).frame(width: 84, height: 84) }
    }
    .buttonStyle(.plain)
    .overlay(alignment: .bottom) {
      if space.onAir, let room = space.room {
        Button { route = .live(room) } label: {
          Text("直播中").font(.caption2.weight(.bold)).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.pink, in: Capsule())
        }.buttonStyle(.plain).offset(y: 2)
      }
    }
    .accessibilityLabel("头像")
  }

  private func stats(_ p: CreatorSpaceRecord.Person?) -> some View {
    HStack(spacing: 0) {
      Button { route = .relations(fans: true) } label: { statCell(p?.fans, "粉丝") }
      Divider().frame(height: 18)
      Button { route = .relations(fans: false) } label: { statCell(p?.following, "关注") }
      Divider().frame(height: 18)
      statCell(p?.likes, "获赞")
    }
    .buttonStyle(.plain)
  }
  private func statCell(_ n: Int64?, _ label: String) -> some View {
    VStack(spacing: 2) {
      Text(n.map { $0.formatted(.number.notation(.compactName)) } ?? "–")
        .font(.body.weight(.medium).monospacedDigit()).contentTransition(.numericText())
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity).contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private func actions(_ p: CreatorSpaceRecord.Person?) -> some View {
    HStack(spacing: 8) {
      if accounts.state.active == String(mid) {
        Button { route = .edit } label: { pill("编辑资料", tint: false) }
        Button { route = .account } label: { square("person.badge.key") }.accessibilityLabel("账号")
      } else if let uid = accounts.state.active {
        followButton(uid, followsViewer: p?.followsViewer == true)
        Button { route = .chat } label: { square("envelope") }.accessibilityLabel("发消息")
      } else {
        NavigationLink { QRLoginView() } label: { pill("登录后关注", tint: true) }
      }
    }
    .buttonStyle(.plain)
    .disabled(busy)
  }
  private func pill(_ title: String, symbol: String? = nil, tint: Bool, danger: Bool = false) -> some View {
    HStack(spacing: 4) {
      if let symbol { Image(systemName: symbol).font(.footnote.weight(.semibold)) }
      Text(title)
    }
    .font(.subheadline.weight(.medium))
    .foregroundStyle(tint ? Color.white : danger ? Color.red : Color.secondary)
    .frame(maxWidth: .infinity).frame(height: 34)
    .background(tint ? Color.accentColor : Color(uiColor: .tertiarySystemFill),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .contentShape(Rectangle())
  }
  private func square(_ symbol: String) -> some View {
    Image(systemName: symbol).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
      .frame(width: 40, height: 34)
      .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .contentShape(Rectangle())
  }
  @ViewBuilder private func followButton(_ uid: String, followsViewer: Bool) -> some View {
    if let relation, relation.attribute == 128 {
      Button { reviewedOwner = uid; confirmBlock = true } label: {
        pill("已拉黑", symbol: "nosign", tint: false, danger: true)
      }
    } else if let relation, relation.followed {
      Menu {
        Button(relation.special == 1 ? "取消特别关注" : "设为特别关注",
          systemImage: relation.special == 1 ? "star.slash" : "star") {
          Task { await special(uid, enabled: relation.special != 1) }
        }
        Button("设置关注分组", systemImage: "folder") { route = .groups(uid) }
        if let stamp = relation.mtime, stamp > 0 {
          Button("关注于 " + Date(timeIntervalSince1970: Double(stamp)).formatted(date: .abbreviated, time: .omitted),
            systemImage: "clock") {}
            .disabled(true)
        }
        Button("取消关注", systemImage: "person.badge.minus", role: .destructive) {
          TouchFeedback.light(); reviewedOwner = uid; confirmUnfollow = true
        }
      } label: {
        pill(relation.special == 1 ? "特别关注" : followsViewer ? "已互粉" : "已关注",
          symbol: relation.special == 1 ? "star.fill" : "line.3.horizontal", tint: false)
      }
    } else {
      Button {
        TouchFeedback.light()
        Task { await act(uid, 1) }
      } label: {
        pill(followsViewer ? "回关" : "关注", symbol: "plus", tint: true)
      }
    }
  }

  private func identity(_ p: CreatorSpaceRecord.Person?, _ h: CreatorSpaceRecord.HeaderDetails) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Button { showPerson = true } label: {
        HStack(spacing: 6) {
          Text(p?.name ?? name).font(.title3.weight(.bold)).lineLimit(1)
            .foregroundStyle(p?.vipStatus == 1 && p?.vipType == 2 ? Color.pink : Color.primary)
          if let level = p?.level { UserLevelBadge(level: Int(level), height: 12) }
          if (p?.vipStatus ?? 0) > 0 {
            Text(p?.vipType == 2 ? "年度大会员" : "大会员").font(.caption2.weight(.semibold))
              .foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 2)
              .background(Color.pink, in: Capsule())
          }
        }
      }
      .buttonStyle(.plain)
      if let type = p?.verifyType, type >= 0, let text = p?.verifyText, !text.isEmpty {
        HStack(spacing: 5) {
          Image(systemName: "bolt.circle.fill")
            .foregroundStyle(.white, type == 1 ? Color(red: 0.25, green: 0.77, blue: 1) : Color(red: 1, green: 0.7, blue: 0.1))
          Text((type == 1 ? "bilibili机构认证：" : "bilibili个人认证：") + text).lineLimit(1)
            .foregroundStyle(.secondary)
          Spacer(minLength: 8)
          Button("详情") { showPerson = true }.buttonStyle(.plain).foregroundStyle(.tint)
        }
        .font(.footnote)
      }
      if let sign = p?.sign, !sign.isEmpty {
        Text(sign).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
          .textSelection(.enabled)
      }
      let tags = h.tags.compactMap(\.title).prefix(4)
      if !tags.isEmpty {
        HStack(spacing: 12) {
          ForEach(Array(tags), id: \.self) { t in
            HStack(spacing: 3) {
              if t.hasPrefix("IP") { Image(systemName: "mappin.and.ellipse") }
              Text(t).lineLimit(1)
            }
          }
        }
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: Sections

  private var sectionKey: String {
    "\(mid):\(accounts.state.active ?? ""):\(selected?.param ?? ""):\(category ?? ""):\(order):\(hideGoods):\(dynamicPattern):\(loadedKey != nil)"
  }

  @ViewBuilder private func sectionBody(_ tab: CreatorSpaceRecord.Tab, _ data: CreatorSpaceRecord) -> some View {
    switch CreatorSection(param: tab.param) {
    case .home:
      SpaceHomeSection(data: data, mid: mid, owner: accounts.state.active == String(mid)) {
        if tabs.contains(where: { $0.param == "contribute" }) {
          category = nil
          selectedTab = "contribute"
        } else {
          route = .library
        }
      }
    case .dynamic:
      ForEach(dynamics.items) { d in DynamicCard(entry: d) { dynamics.reload() } }
      InlinePagerFooter(pager: dynamics, empty: "暂无动态")
    case .contribute:
      contributions(data.contributions(tab))
    case .favorite:
      SpaceFolderSection(model: folders)
    case .bangumi:
      ForEach(bangumi.items) { row in CreatorMediaLink(row: row).padding(.horizontal, 12) }
      InlinePagerFooter(pager: bangumi, empty: "暂无追番")
    case .cheese:
      SpaceLinkRow(title: "查看全部课程", symbol: "graduationcap") { CoursesView(mid: String(mid)) }
    case .shop:
      SpaceLinkRow(title: "逛逛小店", symbol: "bag") { CreatorShop(mid: mid) }
    default:
      EmptyView()
    }
  }

  private static func categoryTitle(_ t: CreatorSpaceRecord.Tab) -> String {
    t.title ?? [
      "video": "视频", "charging_video": "充电专属", "article": "专栏", "opus": "图文", "audio": "音频",
      "comic": "漫画", "series": "列表", "season_video": "合集", "ugcSeason": "全部合集/列表",
    ][t.param] ?? "投稿"
  }
  private func currentCategory(_ list: [CreatorSpaceRecord.Tab]) -> CreatorSpaceRecord.Tab? {
    list.first { $0.id == category } ?? list.first
  }
  /// Archive source for the selected contribution category; nil for the kinds shown elsewhere.
  private func archiveSource(_ tab: CreatorSpaceRecord.Tab?) -> CreatorArchiveSource? {
    switch tab?.param {
    case nil, "video": return .uploads(mid)
    case "season_video": return tab?.season.map { .season(mid, $0) }
    case "series": return tab?.series.map { .series(mid, $0) }
    default: return nil
    }
  }
  private func scope(_ source: CreatorArchiveSource, title: String) -> CreatorArchiveScope {
    .init(source: source, title: title, order: source.uploads ? order : "pubdate", reverse: false, tid: 0,
      special: nil, term: "", owners: .init(accounts.state))
  }

  @ViewBuilder private func contributions(_ list: [CreatorSpaceRecord.Tab]) -> some View {
    let current = currentCategory(list)
    if list.count > 1 {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(list) { t in
            let on = t.id == current?.id
            Button {
              TouchFeedback.light()
              category = t.id
            } label: {
              Text(Self.categoryTitle(t)).font(.subheadline).lineLimit(1)
                .foregroundStyle(on ? Color.accentColor : Color.primary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(on ? Color.accentColor.opacity(0.12) : Color(uiColor: .tertiarySystemFill),
                  in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
      }
    }
    if let source = archiveSource(current) {
      let title = current.map(Self.categoryTitle) ?? "投稿"
      HStack {
        Button {
          playing = SpacePlay(scope: scope(source, title: title))
        } label: {
          Label("播放全部", systemImage: "play.circle").font(.subheadline.weight(.medium))
        }
        .buttonStyle(.plain).foregroundStyle(.tint)
        Spacer()
        if source.uploads {
          Menu {
            Picker("排序", selection: $order) {
              Text("最新发布").tag("pubdate")
              Text("最多播放").tag("click")
              Text("最多收藏").tag("stow")
            }
          } label: {
            Label(order == "click" ? "最多播放" : order == "stow" ? "最多收藏" : "最新发布",
              systemImage: "line.3.horizontal.decrease")
              .font(.subheadline).foregroundStyle(.secondary)
          }
        }
      }
      .padding(.horizontal, 12).padding(.vertical, 8)
      ForEach(uploads.items) { v in SpaceArchiveRow(video: v) }
      InlinePagerFooter(pager: uploads, empty: "暂无视频")
    } else if let current {
      let title = Self.categoryTitle(current)
      switch current.param {
      case "charging_video":
        SpaceLinkRow(title: "查看" + title, symbol: "bolt") { CreatorMobileMedia(mid: mid, kind: .charging).navigationTitle(title) }
      case "article":
        SpaceLinkRow(title: "查看全部专栏", symbol: "doc.richtext") { CreatorWorks(mid: mid, kind: .articles) }
      case "opus":
        SpaceLinkRow(title: "查看全部图文", symbol: "photo.on.rectangle") { CreatorOpus(mid: mid) }
      case "audio":
        SpaceLinkRow(title: "查看全部音频", symbol: "music.note") { CreatorWorks(mid: mid, kind: .albums) }
      case "comic":
        SpaceLinkRow(title: "查看全部漫画", symbol: "book") { CreatorComics(mid: mid) }
      default:
        SpaceLinkRow(title: "查看全部合集和列表", symbol: "square.stack") { CreatorCollections(mid: mid) }
      }
    }
  }

  /// Starts (or keeps) the rows of the section on screen and of its neighbours, so a swipe lands
  /// on a page that has already loaded.
  private func prepareSections() {
    guard let space, let index = tabs.firstIndex(where: { $0.param == selected?.param }) else { return }
    for i in [index, index + 1, index - 1] where tabs.indices.contains(i) {
      prepare(tabs[i], space)
    }
  }
  private func prepare(_ tab: CreatorSpaceRecord.Tab, _ space: CreatorSpaceRecord) {
    let uid = accounts.state.active ?? ""
    switch CreatorSection(param: tab.param) {
    case .dynamic:
      dynamics.start(key: "\(mid):\(uid):\(hideGoods):\(dynamicPattern)") { cursor in
        try await BiliAPI.shared.dynamics(offset: cursor, author: mid, user: uid)
      }
    case .contribute:
      let current = currentCategory(space.contributions(tab))
      guard let source = archiveSource(current) else { return }
      let s = scope(source, title: current.map(Self.categoryTitle) ?? "投稿")
      if s.source.uploads && !s.filtered {
        // Unfiltered uploads walk the playlist cursor, as the full browser does; the web search
        // is only needed for 最多收藏 and is the one more likely to be rate limited.
        let walker = CreatorPlaybackCursor(s, type: 1, desc: true, sort: s.sortField, reportable: false)
        uploads.start(key: s.storageKey) { cursor in
          let n = Int(cursor ?? "1") ?? 1
          let slice = try await walker.browsing(n)
          return Page(items: slice.videos, next: slice.later ? String(n + 1) : nil)
        }
      } else {
        uploads.start(key: s.storageKey) { cursor in
          let n = Int(cursor ?? "1") ?? 1
          let p = try await CreatorArchiveCatalog.page(s, n, size: 30)
          return Page(items: p.videos, next: p.more ? String(n + 1) : nil)
        }
      }
    case .favorite:
      Task { await folders.start(mid: mid, owner: uid) }
    case .bangumi:
      let initial = space.groups.first { $0.kind == .season }
      bangumi.start(key: "\(mid):\(uid)") { cursor in
        try await Self.bangumiPage(mid: mid, cursor: cursor, initial: initial)
      }
    default:
      break
    }
  }
  private static func bangumiPage(mid: Int64, cursor: String?, initial: CreatorSpaceRecord.Group?) async throws
    -> Page<CreatorSpaceRecord.Media>
  {
    struct Payload: Decodable { let item: [CreatorSpaceRecord.Item]?, count: Int?, has_next: Bool? }
    if cursor == nil, let initial, !initial.items.isEmpty {
      return Page(items: initial.items, next: initial.items.count < initial.count ? "2" : nil)
    }
    let page = Int(cursor ?? "1") ?? 1
    let r = try await BiliAPI.shared.read(
      "/x/v2/space/bangumi",
      ["vmid": String(mid), "pn": String(page), "ps": "20", "qn": "32", "mobi_app": "iphone", "platform": "ios"],
      host: "app.bilibili.com", as: Payload.self)
    let raw = r.item ?? []
    let more = r.has_next ?? r.count.map { page * 20 < $0 } ?? (raw.count == 20)
    return Page(items: raw.compactMap { $0.row(.season) }, next: more && !raw.isEmpty ? String(page + 1) : nil)
  }

  @MainActor private func refresh(_ param: String) async {
    revision += 1
    switch CreatorSection(param: param) {
    case .dynamic: dynamics.reload()
    case .contribute: uploads.reload()
    case .bangumi: bangumi.reload()
    case .favorite: await folders.reload()
    default: break
    }
    try? await Task.sleep(for: .milliseconds(500))
  }

  // MARK: Menu and destinations

  private var moreMenu: some View {
    Menu {
      Section {
        Button("空间内容", systemImage: "square.grid.2x2") { route = .library }
        if let r = space?.room, space?.onAir == true {
          Button("直播间", systemImage: "dot.radiowaves.left.and.right") { route = .live(r) }
        }
      }
      Section {
        if let url = URL(string: "https://space.bilibili.com/" + String(mid)) {
          ShareLink("分享主页", item: url)
        }
        Button("复制空间链接", systemImage: "link") {
          UIPasteboard.general.string = "https://space.bilibili.com/" + String(mid)
        }
        if let shortcut = URL(string: "https://www.bilibili.com/blackboard/disablelink/go-to-up-space.html?mid=" + String(mid)) {
          Link(destination: shortcut) { Label("添加主页快捷方式", systemImage: "plus.app") }
        }
      }
      if let uid = accounts.state.active, uid != String(mid) {
        Section {
          Button("共同关注", systemImage: "person.2") { route = .shared(uid, also: false) }
          Button("我关注的人也关注了 TA", systemImage: "person.3") { route = .shared(uid, also: true) }
        }
        Section {
          if header?.followsViewer == true && !removedFan {
            Button("移除粉丝", systemImage: "person.crop.circle.badge.minus", role: .destructive) {
              reviewedOwner = uid; confirmRemoveFan = true
            }
          }
          if let relation {
            Button(relation.attribute == 128 ? "移出黑名单" : "加入黑名单",
              systemImage: "hand.raised", role: .destructive) {
              reviewedOwner = uid; confirmBlock = true
            }
          }
          Button("举报用户", systemImage: "exclamationmark.bubble", role: .destructive) {
            route = .report(uid)
          }
        }
      } else if accounts.state.active == nil {
        Button("在本机屏蔽", systemImage: "hand.raised") {
          do { _ = try LocalCreatorBlockFile.merge([mid]); issue = "已在本机屏蔽" }
          catch { issue = error.localizedDescription }
        }
      }
    } label: {
      Image(systemName: "ellipsis")
    }.accessibilityLabel("更多")
  }
  @ViewBuilder private func destination(_ r: Route) -> some View {
    switch r {
    case .library: CreatorLibrary(mid: mid)
    case .relations(let fans): RelationsList(uid: String(mid), fans: fans)
    case .report(let uid): CommunityReport(target: .person(id: mid), uid: uid)
    case .shared(let uid, let also): SharedFollowing(mid: mid, uid: uid, alsoFollowsCreator: also)
    case .chat:
      ChatHistory(
        conversation: .init(talker_id: mid, session_type: 1, unread_count: nil, last_msg: nil),
        name: header?.name ?? name)
    case .groups(let uid): CreatorGroupEditor(mid: mid, uid: uid)
    case .account:
      Form {
        if (header?.vipStatus ?? 0) > 0 { MemberExperienceButton(uid: String(mid)) { revision += 1 } }
        NavigationLink("登录设备") { LoginDevices(uid: String(mid)) }
        ForEach(AccountLogs.Kind.allCases, id: \.self) { kind in
          NavigationLink(kind.rawValue) { AccountLogs(kind: kind, uid: String(mid)) }
        }
        NavigationLink("空间隐私") { SpacePrivacy(uid: String(mid)) }
      }.navigationTitle("我的账号")
    case .edit: ProfileEditor(uid: String(mid)) { revision += 1 }
    case .reservations: CreatorReservations(items: $reservations)
    case .search: CreatorSearch(mid: mid)
    case .live(let room): LivePlayer(id: room, title: space?.roomTitle ?? "直播间")
    }
  }

  // MARK: Loading and relation

  @MainActor private func loadSpace() async {
    let uid = accounts.state.active
    let key = LoadKey(mid: mid, owner: uid, revision: revision)
    if loadedKey == key {
      if let uid, relation == nil { await loadRelation(uid) }
      return
    }
    let token = UUID()
    loadToken = token
    reviewedOwner = nil
    confirmRemoveFan = false
    confirmBlock = false
    confirmUnfollow = false
    if contentKey?.mid != mid || contentKey?.owner != uid {
      loadedKey = nil
      removedFan = false
      space = nil
      reservations = []
      selectedTab = nil
      relation = nil
    }
    contentKey = key
    loadingError = nil
    async let relationLoad: Void = loadRelation(uid)
    do {
      let result = try await BiliAPI.shared.read(
        "/x/v2/space", CreatorSpaceRequest.fields(mid),
        host: "app.bilibili.com", expectedAccount: uid ?? "", as: CreatorSpaceRecord.self)
      try Task.checkCancellation()
      if accounts.state.active == uid, loadToken == token {
        space = result
        reservations = result.reservations
        loadedKey = key
        if let selectedTab, !result.sections(shop: showShop).contains(where: { $0.param == selectedTab }) {
          self.selectedTab = nil
        }
      }
    } catch {
      if !Task.isCancelled, accounts.state.active == uid, loadToken == token {
        loadingError = error.localizedDescription
      }
    }
    await relationLoad
  }
  @MainActor private func loadRelation(_ uid: String?) async {
    guard let uid, !Task.isCancelled else { return }
    do {
      let r = try await BiliAPI.shared.read(
        "/x/relation", ["fid": String(mid)], expectedAccount: uid, as: CreatorRelation.self)
      try Task.checkCancellation()
      if accounts.state.active == uid { relation = r }
    } catch {
      if accounts.state.active == uid && !Task.isCancelled { issue = error.localizedDescription }
    }
  }
  @MainActor private func act(_ uid: String, _ action: Int) async {
    guard !busy, uid == accounts.state.active, uid != String(mid) else { return }
    busy = true
    defer { busy = false }
    do {
      try await BiliAPI.shared.submit(
        "/x/relation/modify", ["fid": String(mid), "act": String(action), "re_src": "11"],
        expectedAccount: uid)
      guard accounts.state.active == uid else { return }
      if action == 7 { removedFan = true }
      if action == 5 || action == 6 {
        var rules = RecommendationRules.current()
        if action == 5 {
          rules.blockedCreators.insert(mid)
        } else {
          rules.blockedCreators.remove(mid)
        }
        try rules.save()
      }
      await loadRelation(uid)
    } catch { issue = error.localizedDescription }
  }
  @MainActor private func special(_ uid: String, enabled: Bool) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      try await BiliAPI.shared.submit(
        "/x/relation/tag/special/" + (enabled ? "add" : "del"), ["fid": String(mid)],
        expectedAccount: uid)
      await loadRelation(uid)
    } catch { issue = error.localizedDescription }
  }
}

/// The official space's upload row: cover with the length, two-line title, the date, then plays
/// and danmaku with icons and a more menu, over a hairline.
private struct SpaceArchiveRow: View {
  let video: Video
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    HStack(alignment: .bottom, spacing: 0) {
      NavigationLink { DetailView(initial: video) } label: {
        HStack(alignment: .top, spacing: 10) {
          Color.clear.frame(width: 150, height: 84)
            .overlay {
              SiteThumbnail(url: video.cover) { $0.resizable().scaledToFill() } placeholder: {
                Color(uiColor: .tertiarySystemFill)
              }
            }
            .overlay(alignment: .bottomTrailing) {
              if let d = video.duration, d > 0 {
                Text(clockText(Double(d))).font(.caption2.weight(.medium).monospacedDigit())
                  .foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 1.5)
                  .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                  .padding(5)
              }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          VStack(alignment: .leading, spacing: 4) {
            Text(video.title).font(.subheadline).foregroundStyle(.primary)
              .lineLimit(2).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if let date = Self.date(video.pubdate) {
              Text(date).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
              if let n = video.stat?.view { stat("play.rectangle", n) }
              if let n = video.stat?.danmaku { stat("text.bubble", n) }
            }
            .font(.caption).foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, minHeight: 84, maxHeight: 84, alignment: .topLeading)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      Menu {
        if let uid = accounts.state.active {
          Button("稍后再看", systemImage: "clock") {
            Task {
              do {
                try await BiliAPI.shared.submit(
                  "/x/v2/history/toview/add", ["bvid": video.bvid], expectedAccount: uid)
                AppToast.show("已加入稍后再看")
              } catch { AppToast.show(error.localizedDescription) }
            }
          }
        }
        if let url = URL(string: "https://www.bilibili.com/video/" + video.bvid) {
          ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
        }
      } label: {
        Image(systemName: "ellipsis").rotationEffect(.degrees(90))
          .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
          .frame(width: 30, height: 30).contentShape(Rectangle())
      }
      .accessibilityLabel("更多操作")
    }
    .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 10)
    .overlay(alignment: .bottom) { Divider().padding(.leading, 12) }
  }
  private func stat(_ symbol: String, _ n: Int) -> some View {
    HStack(spacing: 3) {
      Image(systemName: symbol)
      Text(n.formatted(.number.notation(.compactName))).monospacedDigit()
    }
  }
  /// Within a day relative ("8分钟前"), then "11月13日" this year and "2024年3月19日" before.
  static func date(_ stamp: Int64?) -> String? {
    guard let stamp, stamp > 0 else { return nil }
    let date = Date(timeIntervalSince1970: TimeInterval(stamp))
    if Date().timeIntervalSince(date) < 86_400 { return MediaStats.published(stamp) }
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
    return f.string(from: date)
  }
}

/// Keeps a page's copy of the header and tabs still on screen while its page slides: page `index`
/// sits at `(index - progress) * width`, so the copy moves back by that much. Only this modifier
/// reads the pager position, so a swipe does not rebuild the pages.
private struct HeldInPlace: ViewModifier {
  let index: Int
  let motion: PagerIndicatorMotion
  let width: CGFloat
  func body(content: Content) -> some View {
    content.offset(x: (motion.progress - CGFloat(index)) * width)
  }
}

/// A page's own rectangle, extended upwards by `raise` (the bar the banner reaches behind).
private struct RaisedClip: Shape {
  var raise: CGFloat
  func path(in rect: CGRect) -> Path {
    Path(CGRect(x: rect.minX, y: rect.minY - raise, width: rect.width, height: rect.height + raise))
  }
}

/// Finds the UIScrollView of the page it sits in.
private struct ScrollerProbe: UIViewRepresentable {
  let found: (UIScrollView) -> Void
  func makeUIView(context: Context) -> Probe {
    let probe = Probe()
    probe.isUserInteractionEnabled = false
    probe.found = found
    return probe
  }
  func updateUIView(_ probe: Probe, context: Context) { probe.found = found }
  final class Probe: UIView {
    var found: ((UIScrollView) -> Void)?
    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard window != nil else { return }
      // The nearest vertical scroller: never the section pager around the pages.
      var view = superview
      while let current = view {
        if let scroller = current as? UIScrollView, scroller.contentSize.width <= scroller.bounds.width + 1 {
          found?(scroller)
          return
        }
        view = current.superview
      }
    }
  }
}

/// The section pages' scroll views, to read and line up their offsets without going through
/// view state (which would rebuild every page on each change).
@MainActor final class SpaceScrollers {
  private final class Ref { weak var view: UIScrollView?; init(_ v: UIScrollView) { view = v } }
  private var pages: [String: Ref] = [:]
  func register(_ key: String, _ view: UIScrollView) { pages[key] = Ref(view) }
  /// Distance scrolled from the top of the page's content.
  func offset(_ key: String) -> CGFloat? {
    guard let s = pages[key]?.view, s.window != nil else { return nil }
    return s.contentOffset.y + s.adjustedContentInset.top
  }
  func setOffset(_ key: String, _ y: CGFloat) {
    guard let s = pages[key]?.view, s.window != nil else { return }
    let top = s.adjustedContentInset.top
    let limit = max(-top, s.contentSize.height + s.adjustedContentInset.bottom - s.bounds.height)
    s.setContentOffset(CGPoint(x: s.contentOffset.x, y: min(max(-top, y - top), limit)), animated: false)
  }
}

/// A section the space links out to instead of listing inline.
private struct SpaceLinkRow<Destination: View>: View {
  let title: String, symbol: String
  @ViewBuilder let destination: () -> Destination
  var body: some View {
    NavigationLink(destination: destination) {
      HStack(spacing: 10) {
        Image(systemName: symbol).foregroundStyle(.tint).frame(width: 24)
        Text(title).foregroundStyle(.primary)
        Spacer()
        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
      }
      .font(.body)
      .padding(.horizontal, 16).padding(.vertical, 14)
      .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(12)
  }
}

/// The space home: per group a "视频 43 · 更多" header, then two-up video cards (cover with
/// plays, danmaku and length), three-up posters, or rows, on a grey page like the official app.
struct SpaceHomeSection: View {
  let data: CreatorSpaceRecord, mid: Int64, owner: Bool
  let openUploads: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let room = data.room { liveCard(room).padding(.horizontal, 12).padding(.top, 12) }
      ForEach(data.groups) { group in
        header(group).padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 10)
        switch group.kind {
        case .archive, .coins, .likes:
          grid(2) {
            ForEach(group.items.prefix(group.kind == .archive ? 4 : 2)) { SpaceVideoCard(row: $0) }
          }
        case .season, .comic:
          grid(3) {
            ForEach(group.items.prefix(3)) { CreatorMediaCard(row: $0, portrait: true) }
          }
        default:
          VStack(spacing: 4) {
            ForEach(group.items.prefix(2)) { CreatorMediaLink(row: $0) }
          }.padding(.horizontal, 12)
        }
      }
      if data.groups.isEmpty && data.room == nil {
        ContentUnavailableView("主页暂无内容", systemImage: "square.grid.2x2").padding(.vertical, 30)
      }
    }
    .padding(.bottom, 20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(uiColor: .secondarySystemBackground))
    .buttonStyle(.plain)
  }
  private func grid<C: View>(_ columns: Int, @ViewBuilder _ content: () -> C) -> some View {
    LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: columns),
      alignment: .leading, spacing: 10, content: content
    ).padding(.horizontal, 12)
  }
  @ViewBuilder private func header(_ group: CreatorSpaceRecord.Group) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(group.kind.label).font(.headline)
      Text("\(group.count)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
      if owner, let visible = group.visible {
        Image(systemName: visible ? "eye" : "eye.slash").font(.caption).foregroundStyle(.secondary)
          .accessibilityLabel(visible ? "公开" : "私密")
      }
      Spacer()
      if group.kind == .archive {
        Button(action: openUploads) { more }
      } else {
        NavigationLink {
          switch group.kind {
          case .favorite: CreatorFavorites(mid: mid).navigationTitle("收藏")
          case .coins: CreatorWorks(mid: mid, kind: .coins)
          case .likes: CreatorWorks(mid: mid, kind: .likes)
          case .article: CreatorOpus(mid: mid)
          case .audios: CreatorWorks(mid: mid, kind: .albums)
          case .comic: CreatorComics(mid: mid)
          case .season: CreatorMobileMedia(mid: mid, kind: .season, initial: group).navigationTitle("追番")
          case .archive: CreatorArchiveBrowser(source: .uploads(mid), title: "视频投稿")
          }
        } label: { more }
      }
    }
  }
  private var more: some View {
    HStack(spacing: 2) {
      Text("更多")
      Image(systemName: "chevron.right").font(.caption.weight(.semibold))
    }
    .font(.subheadline).foregroundStyle(.secondary).contentShape(Rectangle())
  }
  private func liveCard(_ room: Int64) -> some View {
    NavigationLink {
      LivePlayer(id: room, title: data.roomTitle ?? "直播间")
    } label: {
      HStack(spacing: 12) {
        Image(systemName: "dot.radiowaves.left.and.right").font(.body.weight(.semibold))
          .foregroundStyle(data.onAir ? Color.white : Color.accentColor)
          .frame(width: 40, height: 40)
          .background(data.onAir ? Color.pink : Color.accentColor.opacity(0.12), in: Circle())
          .symbolEffect(.variableColor.iterative, options: .repeating, isActive: data.onAir)
        VStack(alignment: .leading, spacing: 2) {
          Text(data.onAir ? "正在直播" : "直播间").font(.subheadline.weight(.semibold))
          if let t = data.roomTitle, !t.isEmpty {
            Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
      }
      .padding(12)
      .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .contentShape(Rectangle())
    }
  }
}

/// Official space card: white tile, cover with plays, danmaku and length over a fade, two-line title.
private struct SpaceVideoCard: View {
  let row: CreatorSpaceRecord.Media
  var body: some View {
    NavigationLink {
      CreatorMediaDestination(row: row)
    } label: {
      VStack(alignment: .leading, spacing: 0) {
        Color.clear.aspectRatio(16 / 10, contentMode: .fit)
          .overlay {
            SiteThumbnail(url: row.cover.flatMap(httpsURL)) { $0.resizable().scaledToFill() } placeholder: {
              Color(uiColor: .tertiarySystemFill)
            }
          }
          .overlay(alignment: .bottom) {
            HStack(spacing: 8) {
              if let n = row.plays {
                Label(n.formatted(.number.notation(.compactName)), systemImage: "play.rectangle")
              }
              if let n = row.danmaku {
                Label(n.formatted(.number.notation(.compactName)), systemImage: "text.bubble")
              }
              Spacer(minLength: 0)
              if let s = row.seconds, s > 0 {
                Text(clockText(Double(s)))
              } else if let note = row.note, note.contains(":") {
                Text(note)
              }
            }
            .labelStyle(SpaceStatLabel())
            .font(.caption2.weight(.medium).monospacedDigit()).foregroundStyle(.white).lineLimit(1)
            .padding(.horizontal, 8).padding(.bottom, 6).padding(.top, 18)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom))
          }
          .clipped()
        Text(row.title).font(.subheadline).foregroundStyle(.primary)
          .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
          .padding(.horizontal, 8).padding(.vertical, 8)
      }
      .background(Color(uiColor: .systemBackground))
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
private struct SpaceStatLabel: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 2) {
      configuration.icon
      configuration.title
    }
  }
}

/// The space's favourite folders: created ones, then collected ones, each with its count.
@MainActor @Observable final class SpaceFolders {
  struct Row: Decodable, Identifiable {
    let id: Int64, title: String?, cover: String?, media_count: Int?, type: Int?, state: Int?
    var key: String { "\(type ?? 0):\(id)" }
  }
  private struct Payload: Decodable { let count: Int?, list: [Row]?, has_more: Bool? }
  private struct GroupData: Decodable { let name: String?, mediaListResponse: Payload? }
  var names = ["创建的收藏夹", "收藏和订阅"]
  var values: [[Row]] = [[], []]
  var counts = [0, 0]
  var next = [0, 0]
  var loading = [false, false]
  var ready = false
  var issue: String?
  var busy = false
  @ObservationIgnored private var scope: String?
  @ObservationIgnored private var mid: Int64 = 0
  @ObservationIgnored private var owner = ""

  func start(mid: Int64, owner: String) async {
    let key = "\(mid):\(owner)"
    guard scope != key else { return }
    scope = key
    self.mid = mid
    self.owner = owner
    await reload()
  }
  func reload() async {
    guard let key = scope, !busy else { return }
    busy = true
    defer { busy = false }
    issue = nil
    do {
      let data = try await BiliAPI.shared.read(
        "/x/v3/fav/folder/space", ["up_mid": String(mid), "mobi_app": "iphone", "platform": "ios"],
        expectedAccount: owner, as: [GroupData].self)
      guard scope == key else { return }
      for i in 0..<2 {
        let section = data.indices.contains(i) ? data[i] : nil
        names[i] = section?.name ?? (i == 0 ? "创建的收藏夹" : "收藏和订阅")
        let raw = section?.mediaListResponse?.list ?? []
        var seen = Set<String>()
        values[i] = raw.filter { $0.id > 0 && seen.insert($0.key).inserted }
        counts[i] = section?.mediaListResponse?.count ?? raw.count
        next[i] = raw.count < counts[i] ? 2 : 0
      }
      ready = true
    } catch {
      if scope == key { issue = error.localizedDescription }
    }
  }
  func more(_ index: Int) async {
    let pg = next[index]
    guard let key = scope, !loading[index], pg > 0 else { return }
    loading[index] = true
    defer { loading[index] = false }
    do {
      var q = ["pn": String(pg), "ps": "20", "up_mid": String(mid)]
      if index == 1 { q["platform"] = "web" }
      let page = try await BiliAPI.shared.read(
        index == 0 ? "/x/v3/fav/folder/created/list" : "/x/v3/fav/folder/collected/list", q,
        expectedAccount: owner, as: Payload.self)
      guard scope == key else { return }
      var seen = Set(values[index].map(\.key))
      let raw = page.list ?? []
      values[index].append(contentsOf: raw.filter { $0.id > 0 && seen.insert($0.key).inserted })
      if let n = page.count { counts[index] = n }
      next[index] = !raw.isEmpty && (page.has_more ?? (pg * 20 < counts[index])) ? pg + 1 : 0
    } catch {
      if scope == key { issue = error.localizedDescription }
    }
  }
}

private struct SpaceFolderSection: View {
  let model: SpaceFolders
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if model.ready {
        ForEach(0..<2, id: \.self) { i in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(model.names[i]).font(.headline)
            Text("\(model.counts[i])").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
          }
          .padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 4)
          if model.values[i].isEmpty {
            Text("暂无内容").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
          }
          ForEach(model.values[i], id: \.key) { row in
            if row.state == 1 {
              Label(row.title ?? "已失效", systemImage: "nosign").foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
              NavigationLink {
                CreatorFolderContents(id: row.id, title: row.title ?? model.names[i], collection: row.type == 21)
              } label: {
                MediaRow(
                  cover: row.cover.flatMap(httpsURL), title: row.title ?? "收藏夹",
                  badge: row.type == 21 ? "合集" : nil,
                  subtitle: "\(row.media_count ?? 0) 个内容", thumbWidth: 120)
              }
              .buttonStyle(.plain).padding(.horizontal, 12)
            }
          }
          if model.loading[i] {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 10)
          } else if model.next[i] > 0 {
            Button("加载更多") { Task { await model.more(i) } }
              .piliGlassButton().frame(maxWidth: .infinity).padding(.vertical, 8)
          }
        }
        if let issue = model.issue {
          Text(issue).font(.caption).foregroundStyle(.secondary).padding(12)
        }
      } else if let issue = model.issue {
        VStack(spacing: 10) {
          Text(issue).font(.footnote).foregroundStyle(.secondary)
          Button("重试") { Task { await model.reload() } }.piliGlassButton()
        }.frame(maxWidth: .infinity).padding(.vertical, 60)
      } else {
        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
      }
    }
    .padding(.bottom, 16)
  }
}
