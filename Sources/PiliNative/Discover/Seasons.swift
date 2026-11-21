import AVKit
import SwiftUI

extension BiliAPI {
  func seasons(_ category: Int, page: Int, order: Int) async throws -> Page<Season> {
    struct Result: Decodable {
      let list: [Season]?
      let total: Int?
    }
    let r = try await read(
      "/pgc/season/index/result",
      [
        "season_type": "\(category)", "page": "\(page)", "pagesize": "20", "type": "1",
        "order": "\(order)", "sort": "0",
      ], as: Result.self)
    return .init(items: r.list ?? [], next: page * 20 < (r.total ?? 0) ? "\(page+1)" : nil)
  }
  func seasonInfo(_ id: Int64, expectedAccount: String? = nil) async throws -> SeasonInfo {
    try await read("/pgc/view/web/season", ["season_id": "\(id)"], expectedAccount: expectedAccount, as: SeasonInfo.self)
  }
  func episodeFormats(
    _ episode: SeasonInfo.Episode, language: String? = nil, expectedAccount: String? = nil
  ) async throws -> (DashFormats, [EpisodeClip]) {
    try await playEpisodeService(episode,course:false,language:language,expectedAccount:expectedAccount)

  }
}
struct SeasonView: View {
  let season: Season
  var openedFromPlayback = false
  @EnvironmentObject private var accounts: AccountContext
  private var metadataOwner:String { accounts.state.owner(.role(.heartbeat)) ?? "" }
  private var catalogViewer:String{accounts.state.owner(.role(.video)) ?? ""}
  @State private var info: SeasonInfo?
  @State private var issue: String?
  @State private var reload = 0
  var body: some View {
    Group {
      // As the official app and the original client do, a work opens straight into its play
      // page (the episode to resume, or the first), with the work's facts in the intro. Only a
      // work that cannot play here stays on the catalogue, which says why.
      if let info, info.viewingRestriction == nil, let (episode, group) = info.resume {
        SeasonCatalogEntry(episode: episode, group: group, info: info, id: info.season_id ?? season.id)
      } else {
        List {
          if let info {
            SeasonCatalogView(info: info, fallback: season)
          } else if let issue {
            PageFailure(message: issue) { reload += 1 }
          } else {
            PageLoading()
          }
        }
        .navigationTitle(info?.title ?? season.title)
      }
    }.modifier(ReplyEdgeDismiss(standalone: openedFromPlayback)).task(id: "\(season.id):\(metadataOwner):\(catalogViewer):\(reload)") {
      info = nil; issue = nil
      do { let response = try await BiliAPI.shared.seasonOverview(season.id,byEpisode:false,history:metadataOwner,viewer:catalogViewer); try Task.checkCancellation(); info=response } catch {
        if !Task.isCancelled { issue = error.localizedDescription }
      }
    }
  }
}
struct EpisodePlayer: View {
  @Environment(\.libraryPlaybackPanel) private var libraryPanel
  @StateObject private var bulletInspector = BulletInspector()
  @AppStorage("dm.tap") private var tapBullet = true
  let episode: SeasonInfo.Episode
  var course = false
  var initialSeconds: Double? = nil
  var sequence: [SeasonInfo.Episode] = []
  var queueEnd: CloudAdvance? = nil
  var queueStep: CloudStep? = nil
  @State private var following: SeasonInfo.Episode?
  @State private var resolvedEpisodes=[Int64:SeasonInfo.Episode]()
  private var catalogSequence:[SeasonInfo.Episode]{sequence.map{row in row.barred ? row:(resolvedEpisodes[row.id] ?? row)}}
  var resumeFullscreen = false
  var seasonType: Int? = nil
  var seasonTitle: String? = nil
  var seasonID: Int64? = nil
  /// The work this episode belongs to, for the intro's poster, facts and sections; loaded here
  /// when the page was opened without it (history, queues).
  var season: SeasonInfo? = nil
  @State private var loadedSeason: SeasonInfo?
  @State private var playbackOptions = false
  @State private var bulletSettings = false
  @State private var listening = false
  @State private var listenTransfer: UUID?
  @Environment(\.listenOrigin) private var listenOrigin
  @State private var sharingMoment: MediaMomentSelection?
  @StateObject private var model = PlayerModel()
  @EnvironmentObject private var accounts: AccountContext
  @AppStorage(InterfaceInteraction.preinitialize) private var early = false
  @AppStorage(VideoTransport.autoKey) private var autoplay = true
  @State private var manualTicket: PlaybackEntryID?
  @State private var prepared: PlaybackEntryID?
  private func ticket(_ e: SeasonInfo.Episode) -> PlaybackEntryID {
    .init(source: (course ? "course:" : "episode:") + String(e.id), cid: e.cid, owner: accounts.state.owner(.role(.video)))
  }
  private var dm: Bool {
    get { model.preferences.bullets }
    nonmutating set { model.preferences.bullets = newValue }
  }
  @AppStorage("play.subtitleSize") private var subtitleSize = 16.0
  @AppStorage("play.episodeSkip") private var skip = EpisodeSkipMode.once.rawValue
  @State private var panelOverride: Bool?
  @AppStorage("detail.episodeReplies") private var showReplies = true
  /// The comment count beside 评论, as the video page shows it, once the list has read it.
  @State private var commentCount: Int64?
  @State private var composeBullet = false
  @State private var bulletDraft = ""
  @State private var theater = false
  @State private var theaterCovering = false
  @State private var reload = 0
  private func episodePlaylist(_ current: SeasonInfo.Episode) -> AnyView? {
    let items=catalogSequence;guard items.count>1 else{return nil}
    return AnyView(SeasonEpisodeSelection(episodes:items,current:current.id,course:course){entry in
      try await choose(entry)
    })
  }
  @MainActor private func choose(_ entry: SeasonInfo.Episode) async throws {
    let viewer=accounts.state.owner(.role(.video)),history=accounts.state.owner(.role(.heartbeat)) ?? ""
    let e:SeasonInfo.Episode
    if entry.canRequestPlayback{e=entry}else if !course{e=try await BiliAPI.shared.catalogEpisode(entry,history:history)}else{throw ServiceError("此课时暂不可播放")}
    try Task.checkCancellation()
    guard e.canRequestPlayback,accounts.state.owner(.role(.video))==viewer,accounts.state.owner(.role(.heartbeat)) ?? ""==history else{throw ServiceError("播放账号已切换")}
    resolvedEpisodes[e.id]=e;following=e
  }
  /// The fullscreen 选集 strip: each episode's still, "第 n 集" and its own title.
  private func episodeCards(_ current: SeasonInfo.Episode) -> [PlayerEpisodeCard] {
    let items = catalogSequence
    guard items.count > 1 else { return [] }
    return items.map { e in
      let long = (e.long_title ?? "").trimmingCharacters(in: .whitespaces)
      let heading = Int(e.title) != nil ? "第 \(e.title) \(course ? "课" : "集")" : e.title
      return PlayerEpisodeCard(
        id: "e\(e.id)", cover: e.cover.flatMap(httpsURL), heading: heading,
        title: long.isEmpty ? e.label : long, current: e.id == current.id
      ) { try await choose(e) }
    }
  }

  private func keyboardStep(_ forward: Bool) {
    if let queueStep {
      Task { _ = await queueStep(forward, theater) }
      return
    }
    let active = (following ?? episode).id
    if let next = manualNeighbor(
      active, in: catalogSequence.filter(\.canRequestPlayback).map(\.id), forward: forward,
      wrap: model.preferences.repeatMode == .cycle)
    {
      following = catalogSequence.first { $0.id == next }
    }
  }
  private func screen(_ episode: SeasonInfo.Episode) -> some View {
    Theater(
      player: model.engine,
      overlay: AnyView(
        ZStack(alignment: .bottom) {
          if dm && !theater {
            BulletOverlay(
              items: model.bullets, time: model.seconds, revision: model.revision,
              clock: model.engine, inspector: bulletInspector)
          }
        }),
      interaction: AnyView(
        ZStack {
          if model.ready {
            PlayerGestures(
              model: model, inspector: dm && tapBullet ? bulletInspector : nil,
              enterTheater: { theater = true })
          }
          if model.ready{VStack{Spacer();HStack{EpisodeClipPrompt(model:model);Spacer()}.padding(.leading,6)}.padding(.bottom,44)}
          if dm && tapBullet {
            PinnedBullet(
              inspector: bulletInspector, cid: episode.cid, duration: model.duration,
              seek: model.seek)
          }
        }), caption: AnyView(PlaybackCaption(model: model)),
      marks: AnyView(ViewportMarks(model: model)),timeline:model.timeline, detached: theaterCovering, toggle: model.toggle,
      seek: model.seek, expand: { theater = true }, upscale: model.upscale
    ).environment(\.styledSubtitles,model.captions)
    .environment(\.playerChrome, inlineSlots(episode)).modifier(
      PlayerKeyboard(
        player:model.engine,toggle:{if model.ready{model.toggle()}else{manualTicket=ticket(episode);reload+=1}},
        fullscreen:{theater=true},bullets:{dm.toggle()},step:keyboardStep,foreground:!theater,
        model:model,item:course ? nil:.init(bvid:episode.bvid,aid:episode.aid,episode:episode.id,copyright:1),cid:episode.cid,bvid:episode.bvid))
  }
  /// Bangumi: the original client's intro (poster, facts, actions, seasons, episodes). Courses
  /// keep their own list of tools.
  @ViewBuilder private func information(_ episode: SeasonInfo.Episode) -> some View {
    if course {
      courseInformation(episode)
    } else {
      ScrollView {
        SeasonIntro(
          season: season ?? loadedSeason, episode: episode, sequence: catalogSequence,
          seasonID: seasonID, seasonType: seasonType ?? (season ?? loadedSeason)?.type, model: model,
          sharingMoment: $sharingMoment, choose: { try await choose($0) }, retry: { reload += 1 })
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      // Like the video page's intro: the page sits under the player and its tabs, and only a
      // list that reports itself is inset below them (and folds the player as it scrolls).
      .defaultScrollAnchor(.top).reportsScrollCollapse()
    }
  }
  /// The inline player's own buttons, as on the video page: cast and 更多 at the top (bullet
  /// settings and picture in picture too when wide); subtitles, speed, quality and 选集 at the
  /// bottom of a wide player, in 更多 on a phone.
  private func inlineSlots(_ episode: SeasonInfo.Episode) -> PlayerChromeSlots {
    PlayerChromeSlots(
      headerTrailing: AnyView(
        HStack(spacing: 0) {
          if !course && episode.canRequestPlayback && !episode.preview && !model.isPreview {
            PlayerCastButton(player: model.engine, subject: .episode(
              id: episode.id, cid: episode.cid, title: episode.label, quality: model.quality))
          }
          PlayerMoreButton { playbackOptions = true }
        }),
      headerWide: AnyView(
        HStack(spacing: 0) {
          Button { bulletSettings = true } label: { PlayerGlyph(symbol: "slider.horizontal.3") }
            .accessibilityLabel("弹幕设置")
          PlayerPiPButton(player: model.engine)
        }),
      bottomTrailing: AnyView(
        HStack(spacing: 0) {
          PlayerCaptionMenu(session: model.captions)
          PlayerSpeedMenu(model: model)
        }),
      bottomLeading: sequence.count > 1 || queueStep != nil
        ? AnyView(PlayerStepButtons { keyboardStep($0) }) : nil,
      bottomEpisode: episodePlaylist(episode).map { list in
        AnyView(PlayerEpisodeButton(list: list) { theater = true })
      },
      bottomWide: AnyView(PlayerQualityMenu(model: model)))
  }
  /// What the 更多 sheet (the video page's) can open for an episode.
  private func optionActions(_ episode: SeasonInfo.Episode) -> ArchiveMoreActions {
    var a = ArchiveMoreActions(cid: episode.cid)
    if episode.canRequestPlayback {
      let show = seasonTitle ?? (season ?? loadedSeason)?.title
      a.listen = {
        let track = ListenTrack(episode, course: course, show: show, origin: listenOrigin)
        let at = model.seconds
        model.engine.pause()
        model.playing = false
        listenTransfer = ListenQueue.shared.handoff(track, at: at)
        listening = true
      }
      a.enqueue = { ListenQueue.shared.add(ListenTrack(episode, course: course, show: show, origin: listenOrigin)) }
    }
    a.danmakuSettings = { bulletSettings = true }
    a.reload = { reload += 1 }
    return a
  }
  private func courseInformation(_ episode: SeasonInfo.Episode) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 10) {
        OnlineViewers(timeline:model.timeline,fallback:.init(bvid:episode.bvid,aid:episode.aid,cid:episode.cid))
        WrappingActions {
          Menu("播放工具"){ArchiveSourceTools(model:model);ArchiveTrendToggle(timeline:model.timeline)}
          PlayerLineButton(model: model)
          SleepTimerButton().labelStyle(.iconOnly)
          CaptureButton(player: model.engine).disabled(!model.ready)
          EpisodeBulletAction(cid: episode.cid, bvid: episode.bvid, model: model).labelStyle(
            .iconOnly)
          Toggle("弹幕", isOn: model.preferences.binding(\.bullets))
            .toggleStyle(.button).buttonStyle(.bordered)
          Menu("画质") {
            ForEach(model.availableQualities, id: \.self) { q in
              Button(StreamQuality.name(q)) {
                Task { await model.changeQuality(q, manualVideo: true) }
              }
            }
          }
        }.padding()
        EpisodeListenButton(episode: episode, course: course, seasonTitle: seasonTitle, model: model)
        if let url=ArchiveSharePoint.episode(episode.id,course:course){
          Menu("分享"){ArchiveShareButtons(normal:url){ArchiveSharePoint.episode(episode.id,course:course,time:model.engine.currentTime().seconds)}}
        }
        if let seasonID,seasonID>0 {
          if course {NavigationLink("课程详情") {CourseDetail(id:seasonID)}}
          else {NavigationLink("作品与全部选集"){SeasonView(season:.init(season_id:seasonID,title:seasonTitle ?? "作品",cover:episode.cover ?? "",index_show:nil),openedFromPlayback:true)}}
        }
        if !course && episode.canRequestPlayback && !episode.preview && !model.isPreview {
          CastButton(subject: .episode(id: episode.id, cid: episode.cid, title: episode.label, quality: model.quality), player: model.engine)
        }
        if episode.preview || model.isPreview {Label("试看",systemImage:"play.rectangle")}
        if episode.allowCacheEntry && !model.isPreview {NavigationLink("缓存本集") { DeferredPage { EpisodeCacheView(episode: episode, course: course) } }}
        if let cover = episode.cover.flatMap(httpsURL) {
          GalleryLink([.init(cover)], index: 0) { Label("剧集封面", systemImage: "photo") }
        }
        SeasonEpisodeActions(entry:episode,course:course,series:seasonTitle).id("\(episode.id):\(accounts.state.active ?? "")")
        if !course {
          MediaMomentButton(resource: .episode(episode, category: seasonType, parent: seasonTitle), selection: $sharingMoment)
          IMShareButton(
            card: .init(
              .episode, id: String(episode.id), title: episode.share_copy ?? episode.label,
              thumb: episode.cover.flatMap(httpsURL), link: episode.share_url.flatMap(httpsURL)))
        }
        if !course {
          EngagementBar(
            item: .init(bvid: episode.bvid, aid: episode.aid, episode: episode.id, copyright: 1))
        }
        RepeatPicker(session: model.preferences)
        SessionPlaybackSettings(session: model.preferences)
        NavigationLink("播放器内核") { DeferredPage { PlaybackEngineSettings() } }
        SeasonPlaybackLine(model:model)
        SpokenTrackPicker(model: model)
        NavigationLink("播放器音量") { DeferredPage { AudioLevelSettings() } }
        SubtitlePicker(model: model)
        if let e = model.error ?? model.qualityError {
          Text(e)
          Button("重试") { reload += 1 }
        }

      }.padding(.horizontal, 16).padding(.vertical, 6).frame(maxWidth: .infinity)
    }.defaultScrollAnchor(.top).reportsScrollCollapse()
  }
  /// The tab bar's "点我发弹幕" pill with the bullet switch at its end, as on the video page and in
  /// the official client.
  private func bulletAccessory(_ episode: SeasonInfo.Episode) -> some View {
    HStack(spacing: 0) {
      Button {
        guard accounts.state.active != nil, episode.cid > 0 else { return }
        withAnimation(.snappy(duration: 0.25)) { composeBullet = true }
      } label: {
        // Shortened rather than cut off when a narrow column leaves it little room.
        ViewThatFits(in: .horizontal) {
          Text("点我发弹幕").fixedSize()
          Text("发弹幕").fixedSize()
          Image(systemName: "pencil.line").accessibilityLabel("发弹幕")
        }
        .font(.system(size: 13)).foregroundStyle(.secondary)
          .padding(.leading, 14).padding(.trailing, 10).frame(height: 30)
          .contentShape(Rectangle())
      }.buttonStyle(.plain).disabled(accounts.state.active == nil || episode.cid <= 0)
      Button {
        TouchFeedback.light()
        dm.toggle()
      } label: {
        DanmakuSwitchGlyph(on: dm)
          .frame(width: 40, height: 26)
          .background(Color(uiColor: .systemBackground), in: Capsule())
          .padding(2).contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel(dm ? "关闭弹幕" : "开启弹幕")
    }
    .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
  }
  private func episodePanels(_ episode: SeasonInfo.Episode, oid: Int64?) -> some View {
    PlaybackPanels(
      model: model, key: String(episode.id), canDiscuss: showReplies && (oid ?? 0) > 0,
      selection: $panelOverride, full: { theater = true }, startDeferred: prepared == ticket(episode) ? nil : { manualTicket = ticket(episode); reload += 1 }, playlist: JoinedPlaybackPanels.merge(libraryPanel, episodePlaylist(episode), fullscreen: false),
      accessory: AnyView(bulletAccessory(episode)), commentCount: commentCount
    ) {
      if prepared == ticket(episode) { screen(episode) }
      else {
        PlaybackCover(title: episode.label, url: episode.cover.flatMap(httpsURL), enabled: episode.cid > 0) {
          manualTicket = ticket(episode); reload += 1
        }
      }
    } info: {
      information(episode)
    } replies: {
      if let oid, oid > 0 {
        // Rebuilt only when what it shows changes (see the video page).
        StableContent(key: [String(oid), String(course), episode.label, String(model.duration)]) {
          Discussion(oid: oid, type: course ? 33 : 1, embeddedTitle: episode.label,
            readingCount: { n in commentCount = n })
            .environment(\.replyPlayback, ReplyPlaybackTarget(duration: model.duration, seek: model.seek, model: model))
        }.equatable().id(oid)
      }
    }.linkedDiscussion(oid:oid,type:course ? 33:1,author:nil,
      playback:ReplyPlaybackTarget(duration:model.duration,seek:model.seek,model:model),
      selectComments:{if showReplies {panelOverride=true}})
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if composeBullet, let uid = accounts.state.active, episode.cid > 0 {
        BulletQuickBar(
          cid: episode.cid, bvid: episode.bvid, uid: uid, time: { model.seconds },
          posted: { model.didPost($0, cid: episode.cid) },
          close: { withAnimation(.snappy(duration: 0.25)) { composeBullet = false } },
          draft: $bulletDraft)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .onChange(of: episode.id) { _, _ in commentCount = nil; composeBullet = false; bulletDraft = "" }
  }
  @MainActor private func playEpisode(_ episode: SeasonInfo.Episode) async {
    let key = ticket(episode)
    let mode = PlaybackEntryPolicy.mode(preinitialize: early, autoplay: autoplay, manual: manualTicket == key,
      continuation: following != nil || queueEnd != nil)
    guard mode != .cover else { prepared = nil; model.stop(); return }
    prepared = key
    let presentation = $theater
    let change = $following
    let catalog = catalogSequence
    model.queueEnd = { mode, valid in
      guard valid() else { return .end }
      if let queueEnd { return await queueEnd(presentation.wrappedValue, mode) }
      let ids = catalog.filter(\.canRequestPlayback).map(\.id)
      guard let id = mode.after(episode.id, in: ids),
        let next = catalog.first(where: { $0.id == id })
      else { return mode == .cycle && ids.isEmpty ? .restart : .end }
      if next.id == episode.id { return .restart }
      change.wrappedValue = next
      return .advanced
    }
    let step: ((Bool) -> Void)?
    if sequence.count > 1 || queueStep != nil {
      step = { forward in self.keyboardStep(forward) }
    } else {
      step = nil
    }
    await model.loadEpisode(
      episode, course: course, start: following == nil ? initialSeconds : 0,
      playNow: mode == .play,
      step: step, seasonType: seasonType,seasonID:seasonID)
  }
  var body: some View {
    let episode = following ?? self.episode
    let oid = course ? episode.id : episode.aid ?? ArchiveNumber.av(episode.bvid)
    episodePanels(episode, oid: oid).navigationTitle(episode.label)
      .screenResume(key: "\(course):\(episode.id)") { [model] in
        course ? nil : ScreenResume.episode(episode.id, seconds: model.seconds)
      }
      .task(
      id: "\(reload):\(episode.id):\(accounts.state.active ?? ""):\(accounts.state.owner(.role(.video)) ?? "")"
    ) {
      await playEpisode(episode)
    }
    .onChange(of: early) { _, enabled in
      if prepared == nil || (!enabled && !autoplay && !model.hasPlayed && !model.playing) { reload += 1 }
    }.onChange(of: autoplay) { _, enabled in if enabled && prepared == nil { reload += 1 } }
    .modifier(
      AutoTheater(
        model: model, cid: episode.cid, presented: $theater, inheritPresentation: resumeFullscreen)
    )
    .theaterCover(requested: $theater, player: model.engine, covering: $theaterCovering) { entry in
      TheaterSheet(
        subject: .init(cid: episode.cid, oid: oid, type: course ? 33 : 1,bvid:episode.bvid, aid: episode.aid, comments: showReplies),
        playlist: JoinedPlaybackPanels.merge(libraryPanel, episodePlaylist(episode), fullscreen: true),
        episodes: libraryPanel == nil ? episodeCards(episode) : [], model: model, keyStep: keyboardStep,
        entry: entry, closing: !theater, covered: { theaterCovering = $0 }, close: { theater = false },
        engagement: course
          ? nil : .init(bvid: episode.bvid, aid: episode.aid, episode: episode.id, copyright: 1))
    }
    .mediaMomentSheet($sharingMoment)
    .piliSheet(isPresented: $playbackOptions) { ArchivePlaybackOptions(model: model, actions: optionActions(episode)) }
    .piliSheet(isPresented: $bulletSettings) {
      PiliNavigationStack {
        DanmakuStylePanel().toolbar { Button("完成") { bulletSettings = false } }
      }
      .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    .piliSheet(isPresented: $listening, onDismiss: {
      if let transfer = listenTransfer,
        let t = ListenQueue.shared.returnPosition(transfer, bvid: episode.listenBV, cid: episode.cid)
      {
        model.seek(t)
      }
      listenTransfer = nil
    }) {
      PiliNavigationStack { ListenView().toolbar { Button("完成") { listening = false } } }
    }
    .task(id: "\(seasonID ?? 0):\(accounts.state.owner(.role(.heartbeat)) ?? "")") {
      // Opened without its work (history, a queue): fetch it for the intro.
      guard season == nil, !course, let id = seasonID, id > 0, loadedSeason?.season_id != id else { return }
      let viewer = accounts.state.owner(.role(.video)) ?? ""
      let history = accounts.state.owner(.role(.heartbeat)) ?? ""
      if let s = try? await BiliAPI.shared.seasonOverview(id, byEpisode: false, history: history, viewer: viewer),
        !Task.isCancelled
      {
        loadedSeason = s
      }
    }
    .modifier(VideoPageAppearance()).modifier(PlaybackEdgeInsets())
    .videoPageNavigation(stopOnDisappear: !theater) { model.leavePlaybackPage() }
  }
}
