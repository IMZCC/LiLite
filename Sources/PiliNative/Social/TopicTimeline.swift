import SwiftUI

struct TopicFeed: View {
  let topic: TopicLink
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    let recommend = accounts.state.owner(.role(.recommend)) ?? ""
    let main = accounts.state.active ?? ""
    TopicTimeline(topic: topic, recommend: recommend, main: main)
      .id("\(topic.id):\(recommend):\(main)")
  }
}

private struct TopicPending: Identifiable {
  let id = UUID()
  let kind: TopicToggle, on: Bool
  var label: String { (on ? "" : "取消") + kind.name }
}

@MainActor private final class TopicTimelineState: ObservableObject {
  @Published var header: TopicHeader?
  @Published var headerIssue: String?
  @Published var cards = [TopicCard]()
  @Published var sorts = [TopicSort]()
  @Published var sort = 0
  @Published var issue: String?
  @Published var foldIssue: String?
  @Published var actionIssue: String?
  @Published var loading = false
  @Published var loaded = false
  @Published var busy = false
  @Published var folding: String?
  @Published var next: String?
  @Published var autoPage = false
  @Published var personal: TopicHeader.Item?
  @Published var confirmation: TopicPending?
  private var stamp = UUID(), headerStamp = UUID(), personalStamp = UUID(), visited = Set<String>()
  private struct Request { let id:Int64, recommend:String, reset:Bool, cursor:String?, sort:Int }
  private var failed:Request?
  func loadHeader(_ id: Int64, recommend: String, main: String) async {
    let token = UUID(), mutation = personalStamp
    headerStamp = token
    headerIssue = nil
    do {
      let reply = try await BiliAPI.shared.topicHeader(id, recommend: recommend)
      try Task.checkCancellation()
      guard headerStamp == token else { return }
      header = reply
      if reply.authenticatedOwner == main, !main.isEmpty, mutation == personalStamp, !busy { personal = reply.topic_item }
    } catch { if headerStamp == token && !Task.isCancelled { headerIssue = error.localizedDescription } }
  }
  func load(_ id: Int64, recommend: String, reset: Bool, selection: Int? = nil) async {
    if !reset && (loading || next == nil) { return }
    if let selection {
      sort = selection
      cards = []; next = nil; loaded = false
    }
    await fetch(Request(id:id,recommend:recommend,reset:reset,cursor:reset ? nil:next,sort:sort))
  }
  func retry(_ id:Int64,recommend:String) async {
    guard !loading else{return}
    if let failed,failed.id==id,failed.recommend==recommend {await fetch(failed)}
    else {await load(id,recommend:recommend,reset:true)}
  }
  private func fetch(_ request:Request) async {
    let cursor=request.cursor,reset=request.reset,token=UUID()
    failed=nil
    stamp = token; issue = nil; loading = true; folding = nil; foldIssue = nil
    defer { if stamp == token { loading = false } }
    do {
      let page = try await BiliAPI.shared.topicPage(request.id, cursor: cursor, sort: request.sort, fold: false, owner: request.recommend)
      try Task.checkCancellation()
      guard stamp == token else { return }
      if let list = page.sorts { sorts = list }
      if let chosen = page.shown { sort = chosen }
      let prior = reset ? [] : cards
      cards = TopicPage.unique(prior + page.cards)
      if reset { visited = [] }
      if let cursor { visited.insert(cursor) }
      next = page.next.flatMap { visited.contains($0) ? nil : $0 }
      autoPage = cards.count > prior.count
      loaded = true
    } catch { if stamp == token && !Task.isCancelled { failed=request;issue = error.localizedDescription } }
  }
  func expand(_ key: String, id: Int64, main: String) async {
    guard !loading, folding == nil else { return }
    let token = stamp
    folding = key; foldIssue = nil
    defer { if token == stamp { folding = nil } }
    do {
      let page = try await BiliAPI.shared.topicPage(id, cursor: nil, sort: sort, fold: true, owner: main)
      try Task.checkCancellation()
      guard token == stamp else { return }
      cards = page.expand(key, in: cards)
    } catch { if token == stamp && !Task.isCancelled { foldIssue = error.localizedDescription } }
  }
  func prepare(_ type: TopicToggle, id: Int64, main: String) async {
    guard !main.isEmpty else { actionIssue = "请先登录"; return }
    guard !busy else { return }
    actionIssue = nil
    if let item = personal, let on = type.state(item) {
      await change(.init(kind: type, on: !on), id: id, main: main)
      return
    }
    busy = true
    defer { busy = false }
    do {
      let item = try await BiliAPI.shared.ownTopicState(id, main: main)
      try Task.checkCancellation()
      guard let old = type.state(item) else { throw ServiceError("暂时无法读取操作状态") }
      personal = item
      confirmation = .init(kind: type, on: !old)
    } catch { if !Task.isCancelled { actionIssue = error.localizedDescription } }
  }
  func change(_ intent: TopicPending, id: Int64, main: String) async {
    guard !busy, !main.isEmpty else { return }
    busy = true; actionIssue = nil
    defer { busy = false }
    do {
      try await BiliAPI.shared.setTopic(id, intent.kind, on: intent.on, main: main)
      try Task.checkCancellation()
      guard var item = personal else { return }
      intent.kind.apply(intent.on, to: &item)
      personalStamp = UUID()
      personal = item
    } catch { if !Task.isCancelled { actionIssue = error.localizedDescription } }
  }
}

private struct TopicTimeline: View {
  let topic: TopicLink, recommend: String, main: String
  @StateObject private var state = TopicTimelineState()
  @State private var compose = false
  @Environment(\.colorScheme) private var colors
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
  @AppStorage("social.waterfall") private var waterfall: Bool?
  @AppStorage("layout.horizontal") private var horizontalPref: Bool?
  private var horizontal: Bool { horizontalPref ?? WindowCanvas.shared.large }
  @AppStorage("grid.cardWidth") private var cardWidth = 240.0
  private var item: TopicHeader.Item? { state.header?.topic_item }
  private var name: String { item?.name ?? topic.name }
  var body: some View {
    GeometryReader { geo in
      let width = max(1, geo.size.width - 16)
      let columns = (waterfall ?? horizontal) ? FeedColumnPlan.columns(width: width,
        cardWidth: cardWidth, largeText: typeSize.isAccessibilitySize || voiceOver) : 1
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
          header
          Section {
            if columns > 1 {
              FeedWaterfall(items: state.cards, available: width, viewport: geo.size.height,
                columns: columns) { row($0) }
            } else {
              ForEach(state.cards) { card in
                row(card).frame(maxWidth: min(width, max(150, min(500, cardWidth)) * 2), alignment: .leading)
                  .frame(maxWidth: .infinity)
              }
            }
            footer
          } header: {
            if !state.sorts.isEmpty { order.frame(maxWidth: .infinity, alignment: .leading).background(.background) }
          }
        }.padding(.horizontal, 8)
      }.piliRefreshable { await refresh() }
    }.navigationTitle(name).navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItemGroup(placement: .topBarTrailing) {
          ShareLink(item: TopicAddress.share(topic.id), subject: Text(name), message: Text(name)) {
            Image(systemName: "square.and.arrow.up").accessibilityLabel("分享话题")
          }
          Menu {
            Button("参与话题") { participate() }
            Button(state.personal?.is_fav == true ? "取消收藏" : "收藏话题") { toggle(.favorite) }.disabled(state.busy)
            if !main.isEmpty, let address = TopicAddress.report(topic.id, name: name, dark: colors == .dark) {
              NavigationLink("举报话题") { SitePage(url: address) }
            } else { Button("举报话题") { state.actionIssue = "请先登录" } }
          } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("话题选项") }
        }
      }.piliSheet(isPresented: $compose) {
        DynamicComposer(initialTopic: TopicLink(id: topic.id, name: name)) { Task { await refresh() } }
      }.confirmationDialog(state.confirmation?.label ?? "话题操作", isPresented: Binding(
        get: { state.confirmation != nil }, set: { if !$0 { state.confirmation = nil } }),
        presenting: state.confirmation) { intent in
          Button(intent.label) { Task { await state.change(intent, id: topic.id, main: main) } }
        } message: { _ in Text("使用主账号完成此操作") }
      .task { await refresh() }
  }
  @ViewBuilder private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let host = state.header?.topic_creator, let uid = host.uid, uid > 0 {
        NavigationLink {
          CreatorSpace(mid: uid, name: host.name ?? "话题发起人")
        } label: {
          HStack {
            SiteThumbnail(url: host.face.flatMap(httpsURL)) { $0.resizable().scaledToFill() }
              placeholder: { Image(systemName: "person.crop.circle") }
              .frame(width: 28, height: 28).clipShape(Circle())
            Text(host.name ?? "UID \(uid)")
            Text("发起").foregroundStyle(.secondary)
          }
        }.buttonStyle(.plain)
      }
      Text(name).font(.title2.bold()).textSelection(.enabled)
      if let text = item?.description ?? topic.description, !text.isEmpty {
        Text(text).font(.subheadline).textSelection(.enabled)
      }
      if let item {
        Text("\((item.view ?? 0).formatted(.number.notation(.compactName))) 浏览 · \((item.discuss ?? 0).formatted(.number.notation(.compactName))) 讨论")
          .font(.footnote).foregroundStyle(.secondary)
      }
      ViewThatFits(in: .horizontal) {
        HStack { actions }
        VStack(alignment: .leading) { actions }
      }
      if let message = state.headerIssue {
        HStack { Text(message); Button("重试") { Task { await state.loadHeader(topic.id, recommend: recommend, main: main) } } }.font(.footnote)
      }
      if let err = state.actionIssue { Text(err).font(.footnote).foregroundStyle(.secondary) }
    }.padding(8)
  }
  @ViewBuilder private var actions: some View {
    let display = state.personal ?? item
    action(.like, count: display?.like)
    action(.favorite, count: display?.fav)
    Button("参与话题") { participate() }.buttonStyle(.borderedProminent)
  }
  private func action(_ kind: TopicToggle, count: Int64?) -> some View {
    let on = state.personal.flatMap(kind.state) == true
    let icon = (kind == .like ? "hand.thumbsup" : "star") + (on ? ".fill" : "")
    return Button { toggle(kind) } label: {
      Label(count.map { $0.formatted(.number.notation(.compactName)) } ?? kind.name, systemImage: icon)
    }.buttonStyle(.bordered).disabled(state.busy || item == nil)
      .accessibilityLabel((on ? "取消" : "") + kind.name)
  }
  private var order: some View {
    ScrollView(.horizontal) {
      HStack {
        ForEach(state.sorts) { option in
          Button(option.name) {
            guard option.id != state.sort else { return }
            Task { await state.load(topic.id, recommend: recommend, reset: true, selection: option.id) }
          }.buttonStyle(.bordered).tint(state.sort == option.id ? Color.accentColor : Color.secondary)
            .accessibilityAddTraits(state.sort == option.id ? .isSelected : [])
        }
      }.padding(.vertical, 4)
    }.scrollIndicators(.hidden)
  }
  @ViewBuilder private func row(_ card: TopicCard) -> some View {
    switch card {
    case .dynamic(let entry):
      DynamicCard(entry: entry) { Task { await state.load(topic.id, recommend: recommend, reset: true) } }
    case .fold(let key, let text):
      VStack(alignment: .leading) {
        Button { Task { await state.expand(key, id: topic.id, main: main) } } label: {
          HStack { Label(text, systemImage: "chevron.down"); if state.folding == key { ProgressView() } }
        }.disabled(state.folding != nil || state.loading)
        if let err = state.foldIssue { Text(err).font(.footnote).foregroundStyle(.secondary) }
      }
    case .unknown(_, let text): Text(text).font(.footnote).foregroundStyle(.secondary)
    }
  }
  @ViewBuilder private var footer: some View {
    if let err = state.issue {
      PageFailure(message: err) { Task { await state.retry(topic.id,recommend:recommend) } }
    } else if state.loading { PageLoading() }
    else if state.loaded && state.cards.isEmpty { ContentUnavailableView("暂无话题动态", systemImage: "number") }
    if let next = state.next, state.issue == nil, !state.loading, state.folding == nil {
      Button("加载更多") { Task { await state.load(topic.id, recommend: recommend, reset: false) } }
      if state.autoPage {
        Color.clear.frame(height: 1).id(next).onAppear {
          Task { if state.next == next { await state.load(topic.id, recommend: recommend, reset: false) } }
        }
      }
    }
  }
  private func participate() { if main.isEmpty { state.actionIssue = "请先登录" } else { compose = true } }
  private func toggle(_ kind: TopicToggle) { Task { await state.prepare(kind, id: topic.id, main: main) } }
  private func refresh() async {
    async let heading: Void = state.loadHeader(topic.id, recommend: recommend, main: main)
    await state.load(topic.id, recommend: recommend, reset: true)
    await heading
  }
}
