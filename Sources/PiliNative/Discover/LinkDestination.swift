import SwiftUI

struct IncomingRoute: Identifiable, Hashable {
  let id = UUID()
  let link: SharedLink
}
struct LinkDestination: View {
  let item: SharedLink
  private var destination: (SharedLink, Double?, Int64?) {
    var route = item, start: Double?, cid: Int64?
    while true {
      switch route {
      case .positioned(let link, let time): route = link; start = time
      case .archivePart(let link, let part): route = link; cid = part
      default: return (route, start, cid)
      }
    }
  }
  var body: some View {
    let (target, start, cid) = destination
    switch target {
    case .positioned, .archivePart: EmptyView()
    case .commentOn(let resource, let root, let anchor):
      AnyView(LinkDestination(item: resource).environment(\.linkedReply, LinkedReply(root: root, anchor: anchor)))
    case .album(let rid): DynamicDetail(id: String(rid), byAlbum: true, resolveArticle: true)
    case .cofollow(let mid): LinkedFollowed(mid: mid)
    case .disclosure(let mid): CreatorDisclosure(mid: mid)
    case .browser(let url):
      Form { Section(url.host ?? "网页") { NavigationLink("打开网页") { DeferredPage { SitePage(url: url) } } } }.navigationTitle("网页链接")
    case .sharedPlaylist(let id, let bv): SharedMediaPlaylist(id: id, bvid: bv)
    case .contextVote(let id, let dynamic): VoteView(id: id, dynamic: String(dynamic))
    case .appPage(let page): AppLinkPage(page: page)
    case .favorites(let tab): FavoriteTabDestination(tab: tab)
    case .search(let word): SearchView(keyword: word)
    case .relations(let uid, let fans): RelationsList(uid: String(uid), fans: fans)
    case .course(let id, let ep):
      if ep {HistoryCourseLink(id:id,byEpisode:true,aid:nil,seconds:start)} else { CourseDetail(id:id) }
    case .song(let id): AudioCardEntry(id:id,title:"",origin:.card(id))
    case .video(let id, let p):
      DetailView(
        initial: .preview(id: id, title: id, cover: "", author: nil), initialPage: p, initialCID: cid,
        initialSeconds: start)
    case .archive(let aid, let p): ArchiveLink(aid: aid, page: p, start: start, cid: cid)
    case .season(let id):
      SeasonView(season: Season(season_id: id, title: "影视", cover: "", index_show: nil))
    case .episode(let id): EpisodeLink(id: id, initialSeconds: start)
    case .creator(let id): CreatorSpace(mid: id, name: "用户空间")
    case .room(let id): LivePlayer(id: id, title: "直播间")
    case .dynamic(let id): DynamicDetail(id: id, resolveArticle: true)
    case .community(let id): BubbleCommunity(id: id)
    case .favoriteFolder(let id): FavoriteFolderScreen(id:id)
    case .subscriptionSeason(let id): SubscriptionCollection(item:.init(id:id,type:21,title:"合集"))
    case .topic(let id): TopicFeed(topic: TopicLink(id: id, name: "话题"))
    case .articleList(let id): ArticleCollection(id: id)
    case .opus(let id): DynamicDetail(id: id, resolveArticle: true)
    case .article(let id): ArticleReader(id: id)
    case .music(let id): MusicDetailView(id: id)
    case .match(let id): MatchDetailView(id: id)
    case .replies(let oid, let type, let root, let anchor):
      if type == 1 {
        ArchiveLink(aid: oid, page: nil, start: nil, cid: nil)
          .environment(\.linkedReply, LinkedReply(root: root, anchor: anchor))
      } else if type == 17 {
        DynamicDetail(id: String(oid), resolveArticle: true).environment(\.linkedReply, LinkedReply(root: root, anchor: anchor))
      } else { Discussion(oid: oid, type: type, root: root, anchor: anchor) }
    case .vote(let id): VoteView(id: id, dynamic: "0")
    }
  }
}
private struct ArchiveLink: View {
  let aid: Int64, page: Int?, start: Double?, cid: Int64?
  @State private var v: Video?
  @State private var issue: String?
  @State private var retry = 0
  var body: some View {
    Group {
      if let v {
        DetailView(initial: v, initialPage: page, initialCID: cid, initialSeconds: start)
      } else if let issue {
        PageFailure(message: issue) { retry += 1 }
      } else {
        PageLoading()
      }
    }.task(id: retry) {
      do {
        v = try await BiliAPI.shared.read(
          "/x/web-interface/view", ["aid": "\(aid)"], as: Video.self)
      } catch { issue = error.localizedDescription }
    }
  }
}
struct EpisodeLink: View {
  @EnvironmentObject private var accounts: AccountContext
  private var owner:String {accounts.state.owner(.role(.heartbeat)) ?? ""}
  private var viewer:String{accounts.state.owner(.role(.video)) ?? ""}
  let id: Int64
  var initialSeconds: Double? = nil
  var queueEnd: CloudAdvance? = nil
  var queueStep: CloudStep? = nil
  @State private var sequence: [SeasonInfo.Episode] = []
  @State private var seasonType: Int?
  @State private var seasonTitle: String?
  @State private var sid: Int64?
  @State private var season: SeasonInfo?
  var resumeFullscreen = false
  @State private var episode: SeasonInfo.Episode?
  @State private var error: String?
  @State private var retry = 0
  var body: some View {
    Group {
      if let episode {
        EpisodePlayer(
          episode: episode, initialSeconds: initialSeconds, sequence: sequence, queueEnd: queueEnd,
          queueStep: queueStep,
          resumeFullscreen: resumeFullscreen, seasonType: seasonType, seasonTitle: seasonTitle,seasonID:sid,
          season: season)
      } else if let error {
        PageFailure(message: error) { retry += 1 }
      } else {
        PageLoading()
      }
    }.task(id: "\(id):\(owner):\(viewer):\(retry)") {
      episode=nil;error=nil
      do {
        let s=try await BiliAPI.shared.seasonOverview(id,byEpisode:true,history:owner,viewer:viewer)
        try Task.checkCancellation()
        guard let (entry,group)=s.locate(id) else{throw ServiceError("未找到这一集")}
        let e=try await BiliAPI.shared.catalogEpisode(entry,history:owner)
        try Task.checkCancellation()
        seasonType = s.type
        seasonTitle = s.title
        sid = s.season_id
        season = s
        sequence=group.episodes.map{$0.id==e.id ? e:$0}
        episode = e
      } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
  }
}
private final class ShortRedirect: CertificateSessionDelegate, @unchecked Sendable {
  override func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
struct OpenSharedLink: View {
  @State private var input = ""
  @State private var route: SharedLink?
  @State private var error: String?
  private struct Request: Equatable { let id = UUID(); let input: String }
  @State private var request: Request?
  var body: some View {
    Form {
      Section("链接或编号") {
        TextField("粘贴链接、BV 号或 AV 号", text: $input).keyboardType(.URL).textInputAutocapitalization(
          .never
        ).autocorrectionDisabled()
        Button("打开") { request = Request(input: input) }.disabled(input.isEmpty || request != nil)
      }
      if let error { Text(error).foregroundStyle(.secondary) }
    }.navigationTitle("打开链接").navigationDestination(item: $route) { LinkDestination(item: $0) }
      .onChange(of: input) { _, value in
        if request?.input != value { request = nil }
        error = nil
      }.task(id: request) {
        if let request { await open(request) }
      }.onDisappear { request = nil }
  }
  private func open(_ pending: Request) async {
    defer { if request == pending { request = nil } }
    do {
      guard let candidate = SharedResolver.candidate(pending.input) else { throw ServiceError("无法识别这个链接") }
      let resolved = try await candidate.resolve()
      guard !Task.isCancelled, request == pending, input == pending.input else { return }
      route = resolved
      error = nil
    } catch { if !Task.isCancelled, request == pending, input == pending.input { self.error = error.localizedDescription } }
  }
}
enum SharedResolver {
  case native(SharedLink)
  case short(URL)
  private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
  static func candidate(_ input: String) -> Self? {
    let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if let direct = SharedLink.parse(raw) { return .native(direct) }
    guard let detector else { return nil }
    for match in detector.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
      guard let url = match.url else { continue }
      if let valid = SharedLink.parse(url.absoluteString) { return .native(valid) }
      guard let host = url.host?.lowercased(), ["b23.tv", "bili2233.cn"].contains(host),
        url.user == nil, url.password == nil, url.port == nil,
        ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
      else { continue }
      c.scheme = "https"
      if let u = c.url { return .short(u) }
    }
    return nil
  }
  func resolve() async throws -> SharedLink {
    switch self {
    case .native(let parsed): return parsed
    case .short(let link):
      var r = URLRequest(url: link, timeoutInterval: 10)
      r.httpMethod = "HEAD"
      r.httpShouldHandleCookies = false
      let cfg = URLSessionConfiguration.ephemeral
      cfg.httpCookieStorage = nil
      cfg.httpShouldSetCookies = false
      cfg.urlCredentialStorage = nil
      cfg.urlCache = nil
      let session = URLSession(configuration: cfg, delegate: ShortRedirect(), delegateQueue: nil)
      defer { session.finishTasksAndInvalidate() }
      let (_, res) = try await session.data(for: r)
      try Task.checkCancellation()
      guard let h = res as? HTTPURLResponse, (300..<400).contains(h.statusCode),
        let dest = h.value(forHTTPHeaderField: "Location"), let route = SharedLink.parse(dest)
      else { throw ServiceError("短链接未指向支持的内容") }
      return route
    }
  }
}
