import SwiftUI

enum Shelf: String, CaseIterable {
  case recommended = "推荐"
  case popular = "热门"
}
@MainActor
final class FeedModel: ObservableObject {
  @Published var videos: [Video] = [] {
    didSet {
      contentRevision &+= 1
      retainedIndex = retainedStart.flatMap { id in videos.firstIndex { $0.id == id } }
    }
  }
  private var contentRevision = 0
  @Published var error: String?
  @Published var busy = false
  @Published var finished = false
  private var retainedStart: String?
  private(set) var retainedIndex: Int?
  @Published var autoCursor:Int?
  private(set) var loaded = false
  private var page = 0, token = UUID(), emptyRun = 0
  private struct Request { let shelf:Shelf, reset:Bool, page:Int }
  private var failed:Request?
  func load(_ shelf: Shelf, reset: Bool) async {
    guard !Task.isCancelled else { return }
    if !reset && (busy || finished) { return }
    await fetch(Request(shelf:shelf,reset:reset,page:reset ? 1:page+1))
  }
  func retry(_ shelf:Shelf) async {
    guard !busy, !Task.isCancelled else{return}
    if let failed,failed.shelf==shelf {await fetch(failed)}
    else {await load(shelf,reset:videos.isEmpty)}
  }
  private func fetch(_ request:Request) async {
    let shelf=request.shelf,reset=request.reset,next=request.page
    let mobile = UserDefaults.standard.object(forKey: "feed.mobile") as? Bool ?? true
    let filterSource:RecommendationFilter.Source = shelf == .popular ? .hotOrRank
      : mobile ? .mobileFeed:.feed
    let t = UUID()
    token = t
    busy = true
    error = nil
    failed = nil
    defer { if token == t { busy = false } }
    do {
      let batch =
        try await
        (shelf == .recommended
        ? BiliAPI.shared.recommendations(next, mobile: mobile) : BiliAPI.shared.popular(next))
      guard token == t, !Task.isCancelled else { return }
      let previous = videos
      let revision = contentRevision
      let keepPrevious = reset && shelf == .recommended
        && (UserDefaults.standard.object(forKey: "feed.keepPrevious") as? Bool ?? true)
      let filtering = Task.detached(priority: .userInitiated) {
        var seen = Set(reset ? [] : previous.map(\.id))
        let policy = RecommendationFilter()
        let fresh = batch.items.filter {
          !Task.isCancelled && policy.allows($0, from: filterSource) && seen.insert($0.id).inserted
        }
        let old = keepPrevious ? previous.prefix(previous.count > 200 ? 50 : previous.count).filter {
          !Task.isCancelled && seen.insert($0.id).inserted && policy.allows($0, from: filterSource)
        } : []
        return ((reset ? [] : previous) + fresh + old, old.first?.id, !fresh.isEmpty)
      }
      let result = await withTaskCancellationHandler { await filtering.value } onCancel: { filtering.cancel() }
      guard token == t, revision == contentRevision, !Task.isCancelled else { return }
      if reset { retainedStart = result.1; emptyRun = 0 }
      videos = result.0
      page = next
      // The original keeps loading recommendations as the list scrolls even when a page is
      // filtered away; stop auto-loading only after a few empty pages in a row.
      emptyRun = result.2 ? 0 : emptyRun + 1
      let keepGoing = shelf == .recommended ? emptyRun < 3 : result.2
      autoCursor = keepGoing && batch.next != nil ? next + 1 : nil
      finished = batch.next == nil
      loaded = true
    } catch { if token == t && !Task.isCancelled { failed=request;self.error=error.localizedDescription } }
  }
}
struct FeedView: View {
  @Environment(\.usesSystemSearchTab) private var systemSearch
  @EnvironmentObject private var indicators: UnreadIndicators
  @AppStorage("badge.messageMode") private var messageMode = 2
  @EnvironmentObject private var accounts: AccountContext
  @AppStorage("search.defaultWord") private var useHint = false
  @State private var hint = ""
  @State private var hintScope: String?
  @State private var hintRead: Date?
  @Environment(\.scenePhase) private var hintPhase
  @Environment(\.openPersonalPage) private var openProfile
  /// The avatar comes from the shared profile cache, so returning to this tab never shows the
  /// placeholder again before the same picture.
  @ObservedObject private var profiles = ProfileStore.shared
  private var avatar: URL? {
    accounts.state.active.flatMap { profiles.profiles[$0]?.face }.flatMap(httpsURL)
  }
  @State private var search = false
  @AppStorage(RecommendationRules.key) private var rules = Data()
  @AppStorage("feed.mobile") private var mobile = true
  @AppStorage(NavigationLayout.key) private var layoutData = Data()
  @State private var shelf = NavigationRules.firstChannel(NavigationLayout.current().channels)
  @State private var channelMotion = PagerIndicatorMotion()
  @State private var windowInsets = FeedHeaderInsets()
  @Environment(\.collapseHomeSearch) private var collapseSearch
  @State private var reserved = FeedHeaderInsets()
  @State private var searchHeight: CGFloat = 54
  @State private var headerHeight: CGFloat = 0
  var body: some View {
    PiliNavigationStack {
      let channels = NavigationLayout.read(layoutData).channels
      let travel = collapseSearch ? searchHeight : 0
      GeometryReader { safe in
        VStack(spacing: 0) {
          VStack(spacing: 0) {
            headerRow.padding(.top, 2).padding(.bottom, 8)
              .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { searchHeight = $0 }
              .homeSearchControls()
            if channels.count > 1 {
              HomeChannelBar(channels: channels, shelf: $shelf, motion: channelMotion).padding(.bottom, 6)
            }
          }
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, reserved.leading).padding(.trailing, reserved.trailing)
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
          // Lay out the full exposed page once. The header and page then translate together.
          GeometryReader { viewport in
            deck(channels, viewport: viewport.size)
              .environment(\.homeFeedBottomClearance, travel + safe.safeAreaInsets.bottom)
          }.padding(.bottom, -travel)
        }
        .homeSearchMotion(travel: travel)
        .clipped()
        .ignoresSafeArea(.container, edges: .bottom)
        .padding(.top, reserved.top)
        .onGeometryChange(for: FeedHeaderInsets.self) { proxy in
          guard #available(iOS 27.1, *) else { return FeedHeaderInsets() }
          let regions = proxy.reservedRegions(kind: .division) + proxy.reservedRegions(kind: .occlusion)
          return FeedHeaderInsets.avoiding(width: proxy.size.width, height: headerHeight,
            regions: regions.filter(\.isActive).map(\.frame))
        } action: { reserved = $0 }
        .padding(.top, windowInsets.top)
        .padding(.leading, windowInsets.leading).padding(.trailing, windowInsets.trailing)
        .background {
          FeedWindowSafeArea { windowInsets = $0 }.allowsHitTesting(false).accessibilityHidden(true)
        }
      }
      // Official cards sit on the grouped background so their own surface reads as a card. It is
      // drawn behind the whole home page and never inside a pager page, where a colour reaching
      // into the safe area would feed the header inset and the page size into each other.
      .background { Color(uiColor: .systemGroupedBackground).ignoresSafeArea() }
      .toolbar(.hidden, for: .navigationBar)
      .task(id: accounts.state.active) {
        if let uid = accounts.state.active { await profiles.refresh(uid) }
      }
      .task(id: "\(useHint):\(hintPhase == .active):\(accounts.state.owner(.role(.recommend)) ?? "")") {
        let uid = accounts.state.owner(.role(.recommend)) ?? ""
        guard useHint else { hint = ""; hintRead = nil; hintScope = nil; return }
        guard hintPhase == .active else { return }
        if hintScope != uid { hint = ""; hintRead = nil; hintScope = uid }
        guard hintRead.map({ Date().timeIntervalSince($0) >= 300 }) ?? true else {return}
        if let s = try? await BiliAPI.shared.defaultSearchWord(owner:uid), !Task.isCancelled {
          hint = s; hintRead = Date()
        }
      }
      // The original client opens search as a page with the field on top, not a sheet.
      .navigationDestination(isPresented: $search) {
        SearchView(
          initialHint: hint, embedded: true,
          placement: .navigationBarDrawer(displayMode: .always))
      }
      .piliTabRoot(.home)
      .navigationTitle("首页")
      .toolbarTitleDisplayMode(.inline)
      .toolbar(removing: .title)
      .navigationDestination(for: Video.self) { DetailView(initial: $0) }
    }
  }
  private func deck(_ channels: [HomeChannel], viewport: CGSize) -> some View {
    let owner = accounts.state.owner(.role(.recommend)) ?? ""
    let shelfID = "\(mobile):\(rules.hashValue):\(owner)"
    return RetainedDeck(choices: channels, selection: $shelf, viewport: viewport, onProgress: channelMotion.update) { channel in
      switch channel {
      case .recommended: VideoShelf(shelf: .recommended).id(shelfID)
      case .popular:
        // The original's 排行榜 entrance switches to the ranking channel when the home page has it.
        VideoShelf(shelf: .popular, openRank: channels.contains(.rank) ? { shelf = .rank } : nil)
          .id(shelfID)
      case .rank: Rankings(embedded: true)
      case .live: LiveDirectory(area: nil, child: nil, embedded: true)
      case .bangumi: PGCHome(cinema: false)
      case .cinema: PGCHome(cinema: true)
      }
    }.id("\(accounts.state.active ?? ""):\(owner)")
      .onChange(of: channels) { _, new in
        if !new.contains(shelf) { shelf = NavigationRules.firstChannel(new) }
      }
  }
  private var unreadMessages: Text? {
    UnreadTotals.label(indicators.count(for: accounts.state.active, messages: true), mode: messageMode)
      .map { Text(verbatim: $0) }
  }
  private var headerRow: some View {
    HStack(spacing: 10) {
      if !systemSearch || useHint { searchEntry } else { Spacer(minLength: 0) }
      // The original header: search, the message bell (signed in only), then the avatar.
      // Settings, rankings, live, the season index and "open link" live where the original
      // puts them (我的 page, home channels, the PGC "索引" header, the search page).
      if accounts.state.active != nil {
        NavigationLink {
          Inbox()
        } label: {
          Image(systemName: "bell").font(.system(size: 17, weight: .medium))
            .frame(width: 44, height: 44).contentShape(Circle())
            .overlay(alignment: .topTrailing) {
              if let unreadMessages {
                unreadMessages.font(.system(size: 10, weight: .bold)).monospacedDigit()
                  .foregroundStyle(.white).padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                  .background(.red, in: Capsule()).offset(x: -2, y: 2)
              }
            }
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
        .piliGlass(in: Circle(), interactive: true)
        .accessibilityLabel("消息中心")
      }
      if let openProfile { profileButton(openProfile) }
    }
    .padding(.horizontal, 16)
  }
  private func profileButton(_ open: @escaping @MainActor () -> Void) -> some View {
    let incognito = accounts.state.active != nil && accounts.state.owner(.role(.heartbeat)) == nil
    return Button(action: open) {
      SiteThumbnail(url: avatar) { $0.resizable().scaledToFill() } placeholder: {
        Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
      }
      .frame(width: 38, height: 38).clipShape(Circle())
      .overlay(alignment: .bottomTrailing) {
        if incognito {
          Image(systemName: "eye.slash.fill").font(.system(size: 9, weight: .semibold))
            .padding(3).background(.regularMaterial, in: Circle()).offset(x: 3, y: 3)
        }
      }
    }.buttonStyle(.plain)
      .accessibilityLabel(accounts.state.active == nil ? "登录或查看我的" : "我的")
  }
  private var searchEntry: some View {
    Button {
      search = true
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
        Text(useHint && !hint.isEmpty ? hint : "搜索").lineLimit(1)
        Spacer(minLength: 0)
      }
      .font(.subheadline)
      .foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 44)
      .contentShape(Capsule())
      .piliGlass(in: Capsule(), interactive: true)
    }.buttonStyle(.plain).accessibilityLabel("搜索")
  }
}

private struct HomeChannelBar: View {
  let channels: [HomeChannel]
  @Binding var shelf: HomeChannel
  let motion: PagerIndicatorMotion
  @Environment(\.scrollHomeChannelToTop) private var channelToTop
  @State private var chipWidths: [HomeChannel: CGFloat] = [:]
  private let spacing: CGFloat = 4

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: spacing) {
          // The highlighted label follows the pager's nearest page, not the settled selection.
          let near = channels.indices.contains(motion.nearestIndex) ? channels[motion.nearestIndex] : shelf
          ForEach(Array(channels.enumerated()), id: \.element) { index, c in
            let current = shelf == c
            Button {
              TouchFeedback.light()
              if current { channelToTop() } else { shelf = c }
            } label: {
              Text(c.rawValue)
                .font(.subheadline.weight(near == c ? .semibold : .regular))
                .foregroundStyle(near == c ? Color.primary : Color.secondary)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chipWidths[c] = $0 }
            .background(alignment: .leading) {
              HomeChannelHighlight(index: index, lastIndex: channels.count - 1, motion: motion,
                nextWidth: channels.indices.contains(index + 1) ? chipWidths[channels[index + 1]] : nil,
                spacing: spacing)
            }
            .accessibilityAddTraits(current ? .isSelected : []).id(c)
          }
        }
        .padding(.horizontal, 16)
      }.scrollClipDisabled()
        .onChange(of: shelf, initial: true) { _, c in
          withAnimation(.snappy) { proxy.scrollTo(c, anchor: .center) }
        }
    }
  }
}
/// Keep the capsule in its chip's coordinates when the entire header is settling vertically.
private struct HomeChannelHighlight: View {
  let index: Int, lastIndex: Int
  let motion: PagerIndicatorMotion
  let nextWidth: CGFloat?
  let spacing: CGFloat

  var body: some View {
    let progress = min(max(0, motion.progress), CGFloat(lastIndex))
    if Int(progress) == index {
      GeometryReader { chip in
        let step = progress - CGFloat(index)
        let width = chip.size.width
        Capsule().fill(Color(uiColor: .tertiarySystemFill))
          .frame(width: width + ((nextWidth ?? width) - width) * step, height: chip.size.height)
          .padding(.leading, (width + spacing) * step)
          .frame(width: width, alignment: .leading)
      }
      .allowsHitTesting(false).accessibilityHidden(true)
    }
  }
}

/// The tab container can extend a navigation root under the status bar. Measure just the
/// uncovered part in the feed's own coordinates, including the user's interface scale.
private struct FeedWindowSafeArea: UIViewRepresentable {
  let change: (FeedHeaderInsets) -> Void

  func makeUIView(context: Context) -> Probe { Probe() }
  func updateUIView(_ view: Probe, context: Context) {
    view.change = change
    view.measureAfterLayout()
  }

  final class Probe: UIView {
    var change: ((FeedHeaderInsets) -> Void)?
    private var scheduled = false
    private var last: FeedHeaderInsets?
    private weak var observedTransition: UIViewControllerTransitionCoordinator?

    private func deferDuringNavigation() -> Bool {
      var responder = next
      while let current = responder {
        if let controller = current as? UIViewController,
          let transition = controller.navigationController?.transitionCoordinator {
          if transition === observedTransition { return true }
          observedTransition = transition
          // The navigation transition temporarily translates or scales the feed. Converting
          // the window's safe rect at that point would resize every row under the finger.
          if transition.animate(alongsideTransition: nil, completion: { [weak self] _ in
            self?.observedTransition = nil
            self?.measureAfterLayout()
          }) { return true }
          observedTransition = nil
          return false
        }
        responder = current.next
      }
      return false
    }
    override func didMoveToWindow() { super.didMoveToWindow(); measureAfterLayout() }
    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); measureAfterLayout() }
    override func layoutSubviews() { super.layoutSubviews(); measureAfterLayout() }

    func measureAfterLayout() {
      guard !scheduled, window != nil else { return }
      scheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.scheduled = false
        guard let window = self.window, self.bounds.height > 0, !self.deferDuringNavigation() else { return }
        let safe = self.convert(window.safeAreaLayoutGuide.layoutFrame, from: window)
        let overlap = FeedHeaderInsets.window(bounds: self.bounds, safe: safe,
          rightToLeft: self.effectiveUserInterfaceLayoutDirection == .rightToLeft)
        if self.last != overlap {
          self.last = overlap
          self.change?(overlap)
        }
      }
    }
  }
}

private struct HomeFeedBottomClearance: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
  var homeFeedBottomClearance: CGFloat {
    get { self[HomeFeedBottomClearance.self] }
    set { self[HomeFeedBottomClearance.self] = newValue }
  }
}

private struct VideoShelf: View {
  @Environment(\.homeFeedBottomClearance) private var bottomClearance
  @Environment(\.horizontalSizeClass) private var sizeClass
  struct Feedback {
    let video: Video, group: String, reason: Video.FeedReason, uid: String, index: Int
  }
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.activeCatalogPage) private var channelActive
  @Environment(\.preparedCatalogPage) private var channelPrepared
  @State private var feedback: Feedback?
  @State private var sending = false
  @State private var notice: String?
  let shelf: Shelf
  var openRank: (() -> Void)? = nil
  @StateObject private var model = FeedModel()
  @State private var manualLoad: Task<Void, Never>?
  @State private var paging = FeedScrollPaging()
  @AppStorage("feed.retainedTip") private var tip = true
  @AppStorage("feed.hotEntrances") private var hotEntrances = false
  @AppStorage(HomeCardStyle.featuredKey) private var featuredFirst = false
  var body: some View {
    ScrollViewReader { proxy in shelfScroll(proxy) }
  }
  private func shelfScroll(_ proxy:ScrollViewProxy)->some View {
    let videos = model.videos
    let boundary = tip ? model.retainedIndex : nil
    let split = boundary.flatMap { $0 > 0 ? $0 : nil }
    let firstSection = videos[..<(split ?? videos.endIndex)]
    // The large first card is optional (设置 › 推荐过滤 › 首个推荐使用大卡片); by default every
    // recommendation is an official double-column card.
    let featured = featuredFirst && shelf == .recommended && sizeClass != .regular ? firstSection.first : nil
    return ScrollView {
      CatalogGrid(home: shelf == .recommended, gap: HomeCardStyle.gap, rowSpacing: CGFloat(HomeCardStyle.gap)) {
        Section {
          ForEach(firstSection.dropFirst(featured == nil ? 0 : 1)) { gridCard($0) }
        } header: {
          VStack(alignment: .leading, spacing: 12) {
            shelfHeader
            if boundary == 0 { refreshPrevious(proxy) }
            if let featured { archiveCard(featured, featured: true).padding(.bottom, 8) }
          }.frame(maxWidth: .infinity, alignment: .leading).id("discover.feed.top")
        } footer: {
          if split == nil { pagingFooter }
        }
        if let split {
          Section {
            ForEach(videos[split...]) { gridCard($0) }
          } header: {
            refreshPrevious(proxy)
          } footer: {
            pagingFooter
          }
        }
      }.padding(.horizontal, HomeCardStyle.gap).padding(.top, 4).padding(.bottom, 16 + bottomClearance)
    }
    .environment(\.homeFeedBottomClearance, 0)
    .onScrollGeometryChange(for: Bool.self) { nearEnd($0) } action: { _, near in
      autoPage(nearEnd: near)
    }
    .onScrollPhaseChange { _, phase, context in
      switch phase {
      case .interacting:
        paging.beginDrag()
        autoPage(nearEnd: nearEnd(context.geometry))
      case .decelerating: break
      default: paging.endDrag()
      }
    }
    .environment(\.discoveryCardRemoval,{ change in
      model.videos.removeAll{v in v.bvid==change.archive || (change.creator != nil && v.owner?.mid==change.creator)}
    }).piliRefreshable {
      paging.endDrag()
      await model.load(shelf, reset: true)
    }
    .task(id:channelPrepared) { if channelPrepared && !model.loaded { await model.load(shelf, reset: true) } }
    .onChange(of: channelActive) { _, visible in
      if !visible { paging.endDrag(); manualLoad?.cancel(); manualLoad = nil }
    }
    .onDisappear { paging.endDrag(); manualLoad?.cancel(); manualLoad = nil }
  }

  private func nearEnd(_ geometry: ScrollGeometry) -> Bool {
    FeedScrollPaging.nearEnd(visible: geometry.visibleRect, contentHeight: geometry.contentSize.height)
  }

  private func autoPage(nearEnd: Bool) {
    guard channelActive, !model.busy, model.error == nil, model.autoCursor != nil,
      paging.takePage(nearEnd: nearEnd) else { return }
    startLoad()
  }

  @ViewBuilder private var shelfHeader: some View {
    if shelf == .popular && hotEntrances {
      HStack {
        ForEach(Rankings.Mode.allCases, id: \.self) { mode in
          if mode == .rank, let openRank {
            Button(action: openRank) { Text(mode.rawValue).frame(maxWidth: .infinity) }
          } else {
            NavigationLink {
              Rankings(initial: mode)
            } label: {
              Text(mode.rawValue).frame(maxWidth: .infinity)
            }
          }
        }
      }.buttonStyle(.bordered)
    }
    if let feedback {
      HStack {
        Text(feedback.reason.toast ?? "已反馈").font(.footnote)
        Spacer()
        Button("撤销") { Task { await send(feedback, undo: true) } }
      }.disabled(sending)
    }
    if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
  }

  private func refreshPrevious(_ proxy: ScrollViewProxy) -> some View {
    Button {
      withAnimation { proxy.scrollTo("discover.feed.top", anchor: .top) }
      startLoad(reset: true)
    } label: {
      Label("以下是上次推荐，点此刷新", systemImage: "arrow.up.circle").piliFont(.caption)
    }
  }

  @ViewBuilder private var pagingFooter: some View {
    if let error = model.error {
      VStack(spacing: 12) {
        Text(error).piliFont(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        Button("重试") { startLoad(retry: true) }.buttonStyle(.glass)
      }.frame(maxWidth: .infinity).padding(.vertical, 24)
    } else if model.busy {
      ProgressView().frame(maxWidth: .infinity).padding(.vertical, model.videos.isEmpty ? 120 : 16)
    } else if !model.finished {
      Button("加载更多") { startLoad() }.buttonStyle(.glass).frame(maxWidth: .infinity)
    } else if model.videos.isEmpty {
      ContentUnavailableView("暂无视频", systemImage: "play.rectangle")
    }
  }
  @MainActor private func startLoad(reset: Bool = false, retry: Bool = false) {
    guard reset || !model.busy else { return }
    manualLoad?.cancel()
    manualLoad = Task {
      if retry { await model.retry(shelf) }
      else { await model.load(shelf, reset: reset) }
    }
  }
  /// The official client's double-column card on the grouped background.
  private func gridCard(_ v: Video) -> some View {
    NavigationLink { destination(v) } label: {
      HomeVideoCard(video: v)
    }
    .buttonStyle(.plain)
    .overlay(alignment: .bottomTrailing) { moreMenu(v) }
    .archiveCover(v) { feedbackMenus(v) }
    .disabled(sending)
  }
  @ViewBuilder private func destination(_ v: Video) -> some View {
    if let link = v.recommendLink.flatMap(SharedLink.parse) {
      LinkDestination(item: link)
    } else {
      DetailView(initial: v)
    }
  }
  /// The official card's trailing "⋮": 稍后再看 and the feed's own feedback reasons.
  @ViewBuilder private func moreMenu(_ v: Video) -> some View {
    let aid = v.aid ?? ArchiveNumber.av(v.bvid)
    let viewer = accounts.state.active
    if (viewer != nil && aid != nil) || hasFeedback(v) {
      Menu {
        if let viewer, let aid {
          Button("添加到稍后再看", systemImage: "clock") { addLater(aid, owner: viewer) }
        }
        feedbackMenus(v)
      } label: {
        Image(systemName: "ellipsis").rotationEffect(.degrees(90))
          .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
          .frame(width: 30, height: 30).contentShape(Rectangle())
      }
      .tint(Color(uiColor: .secondaryLabel))
      .padding(.trailing, 2).padding(.bottom, 2)
      .accessibilityLabel("更多操作")
    }
  }
  private func hasFeedback(_ v: Video) -> Bool {
    accounts.state.owner(.role(.recommend)) != nil
      && (v.recommendMenu ?? []).contains {
        ["dislike", "feedback"].contains($0.type) && !($0.reasons ?? []).isEmpty
      }
  }
  @ViewBuilder private func feedbackMenus(_ v: Video) -> some View {
    if let uid = accounts.state.owner(.role(.recommend)) {
      ForEach(Array((v.recommendMenu ?? []).enumerated()), id: \.offset) { _, group in
        if ["dislike", "feedback"].contains(group.type), let reasons = group.reasons,
          !reasons.isEmpty
        {
          Menu(group.type == "dislike" ? "不感兴趣" : "反馈") {
            ForEach(reasons) { r in
              Button(r.name) {
                Task {
                  await send(
                    .init(
                      video: v, group: group.type, reason: r, uid: uid,
                      index: model.videos.firstIndex(where: { $0.id == v.id }) ?? 0),
                    undo: false)
                }
              }
            }
          }
        }
      }
    }
  }
  private func addLater(_ aid: Int64, owner: String) {
    Task { @MainActor in
      do {
        try await BiliAPI.shared.submit(
          "/x/v2/history/toview/add", ["aid": String(aid)], expectedAccount: owner)
        AppToast.show("已加入稍后再看")
      } catch { notice = error.localizedDescription }
    }
  }
  /// The optional large first card.
  private func archiveCard(_ v: Video, featured: Bool) -> some View {
        NavigationLink {
          destination(v)
        } label: {
          VStack(alignment: .leading, spacing: featured ? 10 : 8) {
            Rectangle().fill(.quaternary).aspectRatio(16 / 9, contentMode: .fit)
              .overlay {
                SiteThumbnail(url: v.cover) { img in
                  img.resizable().scaledToFill()
                } placeholder: {
                  Color.clear
                }
              }
              .overlay(alignment: .bottomTrailing) {
                if let d = v.duration {
                  Text(clockText(Double(d))).font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(featured ? 12 : 8)
                }
              }
              .clipShape(RoundedRectangle(cornerRadius: featured ? NativeGlass.panelRadius : NativeGlass.cardRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
              Text(v.title).piliFont(featured ? .title3 : .subheadline, weight: .semibold)
                .lineLimit(2).multilineTextAlignment(.leading)
              if let reason = v.recommendationReason, !reason.isEmpty {
                Text(reason).font(.caption2.weight(.medium)).foregroundStyle(.tint)
              }
              HStack(spacing: 4) {
                if let name = v.owner?.name { Text(name).lineLimit(1) }
                if v.owner?.name != nil, v.stat?.view != nil { Text("·") }
                if let views = v.stat?.view {
                  Text(views.formatted(.number.notation(.compactName)) + "次观看").fixedSize()
                }
              }.piliFont(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, featured ? 4 : 2)
          }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).archiveCover(v) { feedbackMenus(v) }.disabled(sending)
  }
  @MainActor private func send(_ item: Feedback, undo: Bool) async {
    guard !sending, accounts.state.owner(.role(.recommend)) == item.uid else { return }
    sending = true
    notice = nil
    defer { sending = false }
    do {
      try await BiliAPI.shared.feedFeedback(
        item.video, group: item.group, reason: item.reason.id, undo: undo, uid: item.uid)
      guard accounts.state.owner(.role(.recommend)) == item.uid else { return }
      if undo {
        CardPreferenceMutation.restore(item.video,at:item.index,to:&model.videos)
        feedback = nil
      } else {
        model.videos.removeAll { $0.id == item.video.id }
        feedback = item
      }
    } catch { notice = error.localizedDescription }
  }
}
