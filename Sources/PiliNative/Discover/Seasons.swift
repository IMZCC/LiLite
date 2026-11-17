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
    List {
      if let info {
        SeasonCatalogView(info: info, fallback: season)
      } else if let issue {
        PageFailure(message: issue) { reload += 1 }
      } else {
        PageLoading()
      }
    }.modifier(ReplyEdgeDismiss(standalone: openedFromPlayback)).navigationTitle(info?.title ?? season.title).task(id: "\(season.id):\(metadataOwner):\(catalogViewer):\(reload)") {
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
  @AppStorage("play.subtitleSize") private var subtitleSize = 17.0
  @AppStorage("play.episodeSkip") private var skip = EpisodeSkipMode.once.rawValue
  @State private var panelOverride: Bool?
  @AppStorage("detail.episodeReplies") private var showReplies = true
  @State private var theater = false
  @State private var reload = 0
  private func episodePlaylist(_ current: SeasonInfo.Episode) -> AnyView? {
    let items=catalogSequence;guard items.count>1 else{return nil}
    return AnyView(SeasonEpisodeSelection(episodes:items,current:current.id,course:course){entry in
      let viewer=accounts.state.owner(.role(.video)),history=accounts.state.owner(.role(.heartbeat)) ?? ""
      let e:SeasonInfo.Episode
      if entry.canRequestPlayback{e=entry}else if !course{e=try await BiliAPI.shared.catalogEpisode(entry,history:history)}else{throw ServiceError("此课时暂不可播放")}
      try Task.checkCancellation()
      guard e.canRequestPlayback,accounts.state.owner(.role(.video))==viewer,accounts.state.owner(.role(.heartbeat)) ?? ""==history else{throw ServiceError("播放账号已切换")}
      resolvedEpisodes[e.id]=e;following=e
    })
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
      marks: AnyView(ViewportMarks(model: model)),timeline:model.timeline, detached: theater, toggle: model.toggle,
      seek: model.seek, expand: { theater = true }, upscale: model.upscale
    ).environment(\.styledSubtitles,model.captions).modifier(
      PlayerKeyboard(
        player:model.engine,toggle:{if model.ready{model.toggle()}else{manualTicket=ticket(episode);reload+=1}},
        fullscreen:{theater=true},bullets:{dm.toggle()},step:keyboardStep,foreground:!theater,
        model:model,item:course ? nil:.init(bvid:episode.bvid,aid:episode.aid,episode:episode.id,copyright:1),cid:episode.cid,bvid:episode.bvid))
  }
  private func information(_ episode: SeasonInfo.Episode) -> some View {
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
        if episode.allowCacheEntry && !model.isPreview {NavigationLink("缓存本集") { EpisodeCacheView(episode: episode, course: course) }}
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
        NavigationLink("播放器内核") { PlaybackEngineSettings() }
        SeasonPlaybackLine(model:model)
        SpokenTrackPicker(model: model)
        NavigationLink("播放器音量") { AudioLevelSettings() }
        SubtitlePicker(model: model)
        if let e = model.error ?? model.qualityError {
          Text(e)
          Button("重试") { reload += 1 }
        }

      }.padding(.horizontal, 16).padding(.vertical, 6).frame(maxWidth: .infinity)
    }
  }
  private func episodePanels(_ episode: SeasonInfo.Episode, oid: Int64?) -> some View {
    PlaybackPanels(
      model: model, key: String(episode.id), canDiscuss: showReplies && (oid ?? 0) > 0,
      selection: $panelOverride, full: { theater = true }, startDeferred: prepared == ticket(episode) ? nil : { manualTicket = ticket(episode); reload += 1 }, playlist: JoinedPlaybackPanels.merge(libraryPanel, episodePlaylist(episode), fullscreen: false)
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
        Discussion(oid: oid, type: course ? 33 : 1, embeddedTitle: episode.label)
          .environment(\.replyPlayback, ReplyPlaybackTarget(duration: model.duration, seek: model.seek, model: model)).id(oid)
      }
    }.linkedDiscussion(oid:oid,type:course ? 33:1,author:nil,
      playback:ReplyPlaybackTarget(duration:model.duration,seek:model.seek,model:model),
      selectComments:{if showReplies {panelOverride=true}})
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
    episodePanels(episode, oid: oid).navigationTitle(episode.label).task(
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
    .piliFullScreenCover(isPresented: $theater) {
      TheaterSheet(
        subject: .init(cid: episode.cid, oid: oid, type: course ? 33 : 1,bvid:episode.bvid, aid: episode.aid, comments: showReplies),
        playlist: JoinedPlaybackPanels.merge(libraryPanel, episodePlaylist(episode), fullscreen: true), model: model, keyStep: keyboardStep,
        engagement: course
          ? nil : .init(bvid: episode.bvid, aid: episode.aid, episode: episode.id, copyright: 1))
    }
    .mediaMomentSheet($sharingMoment)
    .modifier(VideoPageAppearance()).modifier(PlaybackEdgeInsets()).onDisappear {
      if !theater { model.stop() }
    }
  }
}
