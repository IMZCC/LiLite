import AVFoundation
import Combine

@MainActor
final class PlayerModel: ObservableObject {
  let upscale = UpscaleSession()
  let preferences = PlayerSessionPreferences()
  private var pipBullets: AnyCancellable?, pipSetting: AnyCancellable?
  private var loweredBullets = false
  private var sessionUpdates: AnyCancellable?
  private var recalls: AnyCancellable?, soundUpdates: AnyCancellable?
  private var clockModeUpdates: AnyCancellable?
  private var soundTask: Task<Void, Never>?, progressiveVolume: AudioMeasurements?
  private let systemMedia = SystemMediaControls()
  private let player = AVPlayer()
  let engine: any PlaybackEngine
  let timeline = TimelineState()
  private let history = CloudWatchProgress()
  let progress = PlaybackProgress()
  var seconds: Double {
    get { progress.seconds }
    set { progress.update(newValue, immediate: true) }
  }
  @Published var duration = 0.0
  @Published var playing = false
  @Published private(set) var hasPlayed = false
  @Published private(set) var pictureSize = CGSize.zero
  @Published var ready = false
  @Published var error: String?
  @Published var bullets: [Bullet] = []
  @Published var sponsorDrafts: [SponsorDraft] = []
  @Published var revision = UUID()
  @Published var bulletError: String?
  @Published private(set) var spokenTracks: [SpokenTrack] = []
  @Published private(set) var spokenLanguage: String?
  private var episodeSource: (SeasonInfo.Episode, Bool)?
  var replyCourseEpisode: Int64? { episodeSource.flatMap { $0.1 ? $0.0.id : nil } }
  @Published var audioChoices: [Int] = []
  @Published var audioID: Int? = nil
  @Published var quality = 0 { didSet { upscale.dynamicRange(quality) } }
  @Published var availableQualities: [Int] = []
  @Published var qualityError: String?
  @Published var switching = false
  var rate: Float {
    get { engine.defaultRate }
    set {
      if newValue.isFinite && newValue > 0 {
        engine.defaultRate = newValue
        if engine.engineKind == .avplayer, let item = player.currentItem { VideoTransport.prepare(player, item) }
      }
    }
  }
  init() {
    engine = PlaybackEngineKind.selected == .mpv ? MPVPlayer() : player
    captionChange=captions.objectWillChange.sink{[weak self] _ in
      self?.lastCaptionSpan = nil
      self?.objectWillChange.send()
    }
    let v = UserDefaults.standard.object(forKey: "play.rate") as? Double ?? 1
    engine.defaultRate = SpeedPresets.valid(v) ? Float(v) : 1
    sessionUpdates = preferences.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    preferences.changed = { [weak self] in self?.syncSessionOptions() }
    syncSessionOptions()
    pipBullets = NotificationCenter.default.publisher(for: VideoTransport.pipChanged, object: engine)
      .sink { [weak self] _ in Task { @MainActor in self?.syncPiPBullets() } }
    pipSetting = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
      .map { _ in UserDefaults.standard.bool(forKey: VideoTransport.quietPiPKey) }
      .removeDuplicates().sink { [weak self] _ in Task { @MainActor in self?.syncPiPBullets() } }
    soundUpdates = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
      .map { _ in AudioFilterChoice.snapshot }.prepend(AudioFilterChoice.snapshot)
      .removeDuplicates().dropFirst()
      .debounce(for: .milliseconds(350), scheduler: DispatchQueue.main).sink { [weak self] _ in
        Task { @MainActor in self?.refreshSound() }
      }
    clockModeUpdates = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
      .map { _ in PresentationMode.current }.prepend(PresentationMode.current)
      .removeDuplicates().dropFirst()
      .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
      .sink { [weak self] mode in
        guard let self, mode != .system, self.loader != nil else { return }
        // A manual clock needs sample tables even if this MP4 originally opened in direct mode.
        self.refreshSound()
      }
    recalls = BulletRecall.shared.changes.sink { [weak self] key in
      guard let self, self.activeCID == key.cid else { return }
      self.ownPosts.removeAll { $0.entryID == key.dmid }
      self.bullets.removeAll { $0.entryID == key.dmid }
      self.revision = UUID()
    }
  }
  private func refreshSound() {
    if let mpv = engine as? MPVPlayer {
      mpv.refreshSound(dash?.volume ?? progressiveVolume ?? legacyPlan?.body.volume)
      return
    }
    guard player.currentItem != nil else { return }
    soundTask?.cancel()
    let generation = generation
    soundTask = Task {
      while switching && generation == self.generation && !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      guard generation == self.generation, !Task.isCancelled else { return }
      if ready { wantsStart = engine.timeControlStatus != .paused }
      if legacyPlan != nil {
        await changeLegacy(quality, language: spokenLanguage)
      } else if let url = progressiveURL, let owner = progressiveOwner {
        if AudioFilterChoice.wantsMeasurements, progressiveVolume == nil {
          await reloadLine()
          return
        }
        let stamp = UUID()
        switchStamp = stamp
        switching = true
        defer { if switchStamp == stamp { switching = false } }
        do { try await open(url, owner: owner) } catch {
          if self.generation == generation, switchStamp == stamp, !Task.isCancelled {
            qualityError = error.localizedDescription
          }
        }
      } else if bridge != nil {
        var next: DashFormats?
        if AudioFilterChoice.wantsMeasurements, dash?.volume == nil, let cid = activeCID {
          let oldRequest = switchStamp
          do {
            let owner = try await AccountJar.shared.current(.role(.video))?.id ?? ""
            if let (episode, course) = episodeSource {
              if course {
                next = try await BiliAPI.shared.courseFormats(
                  episode, language: spokenLanguage, expectedAccount: owner)
              } else {
                next = try await BiliAPI.shared.episodeFormats(
                  episode, language: spokenLanguage, expectedAccount: owner
                ).0
              }
            } else if let bv = timeline.source?.bvid {
              next = try await BiliAPI.shared.formats(
                bv, cid: cid, language: spokenLanguage, expectedAccount: owner)
            }
            guard try await AccountJar.shared.current(.role(.video))?.id ?? "" == owner else {
              return
            }
          } catch { next = nil }
          guard oldRequest == switchStamp, generation == self.generation, !Task.isCancelled else {
            return
          }
        }
        await changeQuality(quality, candidate: next)
      }
    }
  }
  private func syncSessionOptions() {
    syncPiPBullets()
    VideoTransport.background(
      engine, temporary: preferences.temporary ? preferences.background : nil)
    systemMedia.setTemporary(preferences.temporary ? preferences.controls : nil)
  }
  private var progressivePreview = false
  var isPreview: Bool { legacyPlan?.preview ?? (progressiveURL != nil ? progressivePreview : (dash?.isPreview ?? false)) }
  private var dash: DashFormats?
  private var mpvFallbacks: [(String, String?)] = []
  private var bridge: DashBridge?
  private var legacyPlan: LegacyDURLPlan?
  private var legacyBridge: LegacyDURLPlayback?
  let captions=SubtitleSession()
  var cues:SubtitleTimeline{captions.timeline}
  private var captionChange:AnyCancellable?
  private var subtitleTask: Task<Void, Never>?
  private var formatTask: Task<Void, Never>?
  private var fallbackTask: Task<Void, Never>?
  private var recoveringItem: UUID?
  private var triedDashFallback = false
  @Published private(set) var clips: [EpisodeClip] = []
  private var clipSkips = EpisodeSkipHistory()
  private var switchStamp = UUID()
  private var generation = UUID(), itemStamp = UUID()
  private var wantsStart = false
  private var pageReturn: (memory: String, owner: String, time: Double, playing: Bool)?
  private var memoryID: String?
  private var pendingPart: (String, Int64)?
  private var resumeAt = 0.0
  private var pendingSeek: UUID?
  @Published var sponsor: [SponsorSegment] = []
  @Published var sponsorError: String?
  private var sponsorTask: Task<Void, Never>?
  @Published private(set) var sponsorRules = SponsorRules.current()
  @Published private(set) var sponsorToast: String?
  private var toastTask: Task<Void, Never>?
  private var sponsorVisits = SponsorVisits()
  private var sponsorStamp = UUID()
  func reloadSponsors() async {
    let stamp = UUID()
    sponsorStamp = stamp
    sponsorRules = SponsorRules.current().padded()
    guard UserDefaults.standard.bool(forKey: "sponsor.enabled"), let source = timeline.source,
      let bv = source.bvid
    else {
      sponsor = []
      sponsorError = nil
      return
    }
    let gen = generation
    do {
      let entries = try await SponsorAPI().segments(bv, source.cid)
      if gen == generation && stamp == sponsorStamp && !Task.isCancelled {
        sponsor = entries.filter { sponsorRules.mode($0) != 4 }
        sponsorError = nil
      }
    } catch {
      if gen == generation && stamp == sponsorStamp && !Task.isCancelled {
        sponsorError = error.localizedDescription
      }
    }
  }
  func skipSponsor(_ s: SponsorSegment) {
    guard s.valid else { return }
    seek(s.segment[1])
    if sponsorRules.toast {
      sponsorToast = "已跳过" + (s.detail?.title ?? "片段")
      toastTask?.cancel()
      toastTask = Task {
        try? await Task.sleep(for: .seconds(2))
        if !Task.isCancelled { sponsorToast = nil }
      }
    }
    if sponsorRules.track {
      let api = try? SponsorAPI()
      Task { try? await api?.viewed(s.id) }
    }
  }
  private var lastSaved = 0
  private var lastCaptionSpan: Int?
  private var sizeObserver: NSKeyValueObservation?
  private var observer: NSKeyValueObservation?
  private var clock: Any?
  var queueEnd: ((VideoRepeat, () -> Bool) async -> NextPlayback)?
  private var storyCID: Int64?
  @Published private(set) var storyOptions: [StoryNode.Choice] = []
  @Published private(set) var storyEnded = false
  private var storyAction: ((StoryNode.Choice) -> Void)?
  private var storyRequest: Task<Void,Never>?
  @Published private(set) var storyError: String?
  private(set) var retryStory: (() -> Void)?
  func clearStory() {
    storyCID = nil; storyRequest = nil; storyEnded = false; storyError = nil
    storyAction = nil; storyOptions = []; retryStory = nil
  }
  func beginStory(_ cid: Int64, wait: Task<Void,Never>?) {
    if storyCID != cid { storyEnded = false }
    storyCID = cid; storyRequest = wait; storyOptions = []; storyAction = nil; storyError = nil; retryStory = nil
  }
  func storyFailed(_ cid: Int64, message: String, retry: @escaping () -> Void) {
    guard storyCID == cid else { return }
    storyError = message; retryStory = retry
  }
  func story(
    _ cid: Int64, choices: [StoryNode.Choice], action: @escaping (StoryNode.Choice) -> Void
  ) {
    storyCID = cid
    storyOptions = choices
    storyAction = action; storyError = nil; retryStory = nil
    if storyEnded && choices.isEmpty { storyEnded = false; finishedAt = UUID() }
  }
  func chooseStory(_ choice: StoryNode.Choice) {
    guard storyCID == activeCID, storyOptions.contains(where: { $0.id == choice.id && $0.cid == choice.cid }) else {
      return
    }
    storyEnded = false
    storyAction?(choice)
  }
  @Published private(set) var finishedAt = UUID()
  private var finishedNotice: NSObjectProtocol?
  private var failedNotice: NSObjectProtocol?
  private var loader: MediaLoader?
  private var mirrors: [URL] = []
  private var progressiveURL: URL?, progressiveOwner: String?
  private var reference: URL?
  private var bulletTask: Task<Void, Never>?
  func load(
    _ bvid: String, cid: Int64, aid: Int64? = nil, start: Double? = nil, rememberPart: Bool = false,
    playNow: Bool = false, mediaTitle: SystemMediaTitle? = nil, step: ((Bool) -> Void)? = nil
  ) async {
    stop()
    wantsStart = false
    let gen = generation
    let user = try? await AccountJar.shared.current()?.id
    let owner: String
    do { owner = try await AccountJar.shared.current(.role(.video))?.id ?? "" }
    catch { if generation == gen { self.error = error.localizedDescription }; return }
    let reporter = try? await AccountJar.shared.current(.role(.heartbeat))?.id
    guard gen == generation, !Task.isCancelled else { return }
    activeVideoOwner = owner
    upscale.begin(id: bvid + ":" + String(cid), anime: false)
    setupSystemMedia(mediaTitle ?? .init(title: bvid), step: step)
    timeline.reset(.init(bvid: bvid, aid: aid, cid: cid))
    history.begin(uid: reporter, fields: ["bvid": bvid, "cid": "\(cid)", "type": "3"])
    restorePageOrStart(memory: PlaybackMemory.id(cid, account: user), owner: owner,
      start: start, autoplay: playNow || VideoTransport.playsOnEntry)
    pendingPart = rememberPart ? (LastArchivePart.key(bvid, uid: user), cid) : nil
    reference = URL(string: "https://www.bilibili.com/video/\(bvid)/")
    startClock(gen)
    reloadSubtitleCatalog()
    sponsorTask = Task { await reloadSponsors() }
    formatTask = Task {
      do {
        let options = try await BiliAPI.shared.formats(bvid, cid: cid, expectedAccount: owner)
        guard gen == generation, !Task.isCancelled else { return }
        adoptFormats(options)
      } catch {}
    }
    activeCID = cid
    activeAID = aid
    loadBullets(at: resumeAt)
    let explicit = engine.engineKind == .mpv || PlaybackOption.needsDash() || preferences.overridden(audio: false) != nil || preferences.overridden(audio: true) != nil
    let preferPublicHD = owner.isEmpty && ArchiveStreamGrant.prefersGuestHD
    if explicit || preferPublicHD {
      await formatTask?.value
      guard gen == generation, !Task.isCancelled else { return }
      let auto = ArchiveStreamGrant.automaticHD(availableQualities, guest: owner.isEmpty, enabled: preferPublicHD, explicit: explicit)
      if let q = auto ?? (explicit ? preferences.preferredQuality(availableQualities) : nil) {
        await changeQuality(q)
        guard gen == generation, !Task.isCancelled else { return }
        if engine.playbackItem != nil { return }
      }
    }
    do {
      let source = try await BiliAPI.shared.playback(bvid, cid: cid, expectedAccount: owner)
      guard !Task.isCancelled, gen == generation else { return }
      reference = source.reference
      progressivePreview = source.preview
      progressiveVolume = source.volume
      quality = source.quality
      mirrors = Array(source.backups.prefix(3))
      try await open(source.url, owner: owner)
    } catch {
      await formatTask?.value
      guard !Task.isCancelled, gen == generation else { return }
      if let quality = availableQualities.first {
        await changeQuality(quality)
        if gen == generation, !Task.isCancelled, engine.playbackItem == nil { self.error = qualityError ?? error.localizedDescription }
      } else {
        do {
          let old = try await BiliAPI.shared.legacyPlayback(bvid, cid: cid, expectedAccount: owner)
          guard gen == generation, !Task.isCancelled else { return }
          try await activateLegacy(old)
        } catch {
          if gen == generation, !Task.isCancelled { self.error = error.localizedDescription }
        }
      }
    }
  }
  private var activeVideoOwner: String?
  private var activeCID: Int64?
  private var activeAID: Int64?
  private var segment = 0
  private var segments: [Int: [Bullet]] = [:]
  private var ownPosts: [Bullet] = []
  func didPost(_ item: Bullet, cid: Int64) {
    guard activeCID == cid else { return }
    ownPosts.append(item)
    if let id = item.entryID, bullets.contains(where: { $0.entryID == id }) { return }
    bullets.insert(item, at: bullets.partitionIndex(after: item.time))
    revision = UUID()
  }
  private func publishSegment(_ previous: [Bullet], _ current: [Bullet], cid: Int64) async throws {
    let removed = BulletRecall.shared.removedIDs(for: cid)
    let work = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      // Each server segment is already sorted. Only overlapping segment boundaries need a re-sort.
      var result = previous + current
      if let last = previous.last, let first = current.first, last.time > first.time {
        result.sort { $0.time < $1.time }
      }
      if !removed.isEmpty { result.removeAll { $0.entryID.map(removed.contains) == true } }
      try Task.checkCancellation()
      return result
    }
    var result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    try Task.checkCancellation()
    guard activeCID == cid else { throw CancellationError() }
    let late = BulletRecall.shared.removedIDs(for: cid).subtracting(removed)
    if !late.isEmpty { result.removeAll { $0.entryID.map(late.contains) == true } }
    for item in ownPosts {
      if result.contains(where: { item.entryID != nil ? $0.entryID == item.entryID : $0 == item }) { continue }
      result.insert(item, at: result.partitionIndex(after: item.time))
    }
    bullets = result
    revision = UUID()
    if bulletError != nil { bulletError = nil }
  }
  private func syncPiPBullets() {
    let quiet = VideoTransport.quietPiP(engine) || !preferences.bullets
    guard loweredBullets != quiet else { return }
    loweredBullets = quiet
    if quiet {
      bulletTask?.cancel(); bulletTask = nil
      segment=0
    } else {
      loadBullets(at: ready ? seconds : resumeAt)
    }
  }
  func retryBullets() { segment = 0; loadBullets(at: ready ? seconds : resumeAt) }
  private func loadBullets(at time: Double) {
    guard time.isFinite, time >= 0, time < 360_000_000 else { return }
    loadSegment(1 + Int(time / 360))
  }
  private func loadSegment(_ index: Int) {
    guard !loweredBullets else { return }
    guard let cid = activeCID, segment != index,preferences.bullets else { return }
    segment = index
    bulletTask?.cancel()
    let gen = generation
    let aid = activeAID
    bulletTask = Task {
      do {
        let v: [Bullet]
        if let saved = segments[index] { v = saved }
        else { v = try await BiliAPI.shared.commentSegment(cid: cid, aid: aid, index: index) }
        guard gen == generation, segment == index, !Task.isCancelled else { return }
        segments[index] = v
        segments = segments.filter { abs($0.key - index) <= 2 }
        try await publishSegment(segments[index - 1] ?? [], v, cid: cid)
      } catch {
        guard gen == generation, !Task.isCancelled else { return }
        bulletError=error.localizedDescription
      }
    }
  }
  func loadEpisode(
    _ e: SeasonInfo.Episode, course: Bool = false, start: Double? = nil, playNow: Bool = false,
    step: ((Bool) -> Void)? = nil, seasonType: Int? = nil, seasonID: Int64? = nil
  ) async {
    stop()
    wantsStart = false
    let gen = generation
    let user = try? await AccountJar.shared.current()?.id
    let reporter = try? await AccountJar.shared.current(.role(.heartbeat))?.id
    guard gen == generation, !Task.isCancelled else { return }
    let episodeOwner: String
    do { episodeOwner = try await AccountJar.shared.current(.role(.video))?.id ?? "" }
    catch { if gen == generation { self.error = error.localizedDescription }; return }
    guard gen == generation, !Task.isCancelled else { return }
    activeVideoOwner = episodeOwner
    let historyFields=e.historyFields(course:course,seasonID:seasonID,seasonType:seasonType)
    upscale.begin(
      id: (course ? "course:" : "ep:") + String(e.id),
      anime: !course && [1, 4].contains(seasonType ?? 0))
    setupSystemMedia(.init(title: e.label, cover: e.cover.flatMap(httpsURL)), step: step)
    timeline.reset(.init(bvid: e.bvid, aid: e.aid, cid: e.cid))
    history.begin(uid: reporter, fields: historyFields)
    restorePageOrStart(memory: PlaybackMemory.id(e.cid, account: user), owner: episodeOwner,
      start: start, autoplay: playNow || VideoTransport.playsOnEntry)
    startClock(gen)
    reference = URL(
      string: "https://www.bilibili.com/" + (course ? "cheese" : "bangumi") + "/play/ep\(e.id)")
    episodeSource = (e, course)
    activeCID = e.cid
    activeAID = e.aid
    if !e.bvid.isEmpty {
      reloadSubtitleCatalog()
    }
    loadBullets(at: resumeAt)
    do {
      let info = try await BiliAPI.shared.playEpisodeInfo(e, course: course, expectedAccount: episodeOwner)
      try Task.checkCancellation()
      guard gen == generation else { return }
      clips = info.clips
      guard let raw = info.dash, !raw.video.isEmpty else {
        _ = try info.legacy.parts
        guard let reference else { throw URLError(.badURL) }
        try await activateLegacy(.init(body: info.legacy, reference: reference, owner: episodeOwner, preview: e.preview || info.preview))
        return
      }
      var options = raw.withLanguages(info.language, info.cur_language, volume: info.volume)
      options.isPreview = e.preview || info.preview
      adoptFormats(options)
      guard let id = preferences.preferredQuality(availableQualities) else {
        throw ServiceError("本集没有可播放的视频流")
      }
      await changeQuality(id)
      if gen == generation, engine.playbackItem == nil { self.error = qualityError ?? "本集暂时无法播放" }
    } catch {
      if gen == generation && !Task.isCancelled { self.error = error.localizedDescription }
    }
  }
  private func startClock(_ gen: UUID) {
    clock = engine.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 1.0 / 15, preferredTimescale: 600), queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.generation == gen, self.ready, self.pendingSeek == nil else { return }
        // A callback queued before a seek can arrive after its completion.
        let t = self.engine.currentTime()
        var instant = t.seconds.isFinite && t.seconds < Double(Int.max) ? max(0, t.seconds) : self.seconds
        let playing = self.engine.rate != 0
        // Publish only to progress consumers, using wall time so faster playback cannot increase
        // SwiftUI invalidations. Segment/skip/heartbeat sampling retains its media-time precision.
        let captionSpan = self.cues.interval(at: instant)
        self.progress.update(instant, immediate: captionSpan != self.lastCaptionSpan || self.playing != playing)
        self.lastCaptionSpan = captionSpan
        if self.playing != playing {
          self.playing = playing
          if playing { self.history.resumed(instant, duration: self.duration) }
        }
        if playing, !self.clips.isEmpty {
          let mode =
            EpisodeSkipMode(
              rawValue: UserDefaults.standard.string(forKey: "play.episodeSkip") ?? "") ?? .once
          if let target = self.clipSkips.target(
            self.clips.first(where: { $0.contains(instant) }), mode: mode)
          {
            self.seek(target)
            instant = target
          }
        }
        if playing,
          let chosen = self.sponsorVisits.next(
            self.sponsor, time: instant, rules: self.sponsorRules)
        {
          self.skipSponsor(chosen)
          instant = chosen.segment[1]
        }
        self.loadBullets(at: instant)
        let d = self.engine.playbackDuration
        if d.isFinite {
          let length = max(0, d)
          if self.duration != length { self.duration = length }
        }
        if self.ready, self.engine.rate > 0 {
          if instant > 0 && !self.hasPlayed { self.hasPlayed = true }
          self.history.record(instant, duration: self.duration)
          if instant > 0, let (key, cid) = self.pendingPart {
            LastArchivePart.played(key, cid: cid)
            self.pendingPart = nil
          }
        }
        if let id = self.memoryID, self.ready, abs(Int(instant) - self.lastSaved) >= 12 {
          self.lastSaved = Int(instant)
          PlaybackMemory.store(id, seconds: instant, duration: self.duration)
        }
      }
    }
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)

  }
  private func open(
    _ url: URL, owner: String, indexed: Bool = false, routes: [NativeVideoRoute]? = nil,
    previous: DashBridge? = nil
  ) async throws {
    guard let reference else { throw URLError(.badURL) }
    let gen = generation
    let request = switchStamp
    func check() async throws {
      try Task.checkCancellation()
      guard (try await AccountJar.shared.current(.role(.video))?.id ?? "") == owner else {
        throw ServiceError("视频账号已切换")
      }
      guard gen == generation, request == switchStamp, !Task.isCancelled else {
        throw CancellationError()
      }
    }
    try await check()
    if let mpv = engine as? MPVPlayer {
      clearItem()
      progressiveURL = url
      progressiveOwner = owner
      mpvFallbacks = mirrors.map { ($0.absoluteString, nil) }
      error = nil
      qualityError = nil
      startMPV(mpv, video: url.absoluteString, audio: nil, reference: reference,
        autoplay: wantsStart, volume: progressiveVolume)
      return
    }
    let order =
      DecoderPreference.choices(
        UserDefaults.standard.string(forKey: DecoderPreference.listKey) ?? "auto") ?? ["auto"]
    let first = order.first(where: DecoderPreference.local.contains) ?? "auto"
    let requiresIndex = indexed || !AudioFilterChoice.current(progressiveVolume).isEmpty
      || !DecoderPreference.allowsSystemFallback
      || ["no", "auto-copy", "videotoolbox-copy"].contains(first)
    // Native playback can consume the authorized MP4 directly. Build fragment tables only for
    // an explicit clock/decoder/effect or when recovering from a direct playback failure.
    if !requiresIndex && PresentationMode.current == .system && routes == nil {
      attachProgressive(url, reference: reference, owner: owner)
      return
    }
    do {
      let result: (bridge: DashBridge, url: URL)
      if let previous, let routes {
        result = try await previous.reopenProgressive(routes: routes)
      } else {
        result = try await ProgressiveDecoderBridge.open(
          url: url, reference: reference, quality: quality, owner: owner, volume: progressiveVolume,
          routes: routes)
      }
      do { try await check() } catch {
        result.bridge.close()
        throw error
      }
      clearItem()
      bridge = result.bridge
      progressiveURL = url
      progressiveOwner = owner
      error = nil
      qualityError = nil
      observe(AVPlayerItem(url: result.url), autoplay: wantsStart)
      return
    } catch {
      try await check()
      guard !requiresIndex else{throw error}
      switch error {
      case LocalIndexIssue.invalid,LocalIndexIssue.notFragmented,DecoderProblem.unsupported,DecoderProblem.size: break
      case let e as URLError where e.code == .badServerResponse: break
      default: throw error
      }
    }
    attachProgressive(url, reference: reference, owner: owner)
  }
  private func attachProgressive(_ url: URL, reference: URL, owner: String) {
    clearItem()
    let l = MediaLoader(url: url, reference: reference) {
      guard (try await AccountJar.shared.current(.role(.video))?.id ?? "") == owner else {
        throw ServiceError("视频账号已切换")
      }
    }
    loader = l
    progressiveURL = url
    progressiveOwner = owner
    observe(l.makeItem(), autoplay: wantsStart)
  }
  private func supportsVideo(_ stream: DashStream) -> Bool { PlaybackOption.supportsVideo(stream, engine: engine.engineKind) }
  private func supportsAudio(_ stream: DashStream) -> Bool { PlaybackOption.supportsAudio(stream, engine: engine.engineKind) }
  private func chooseVideo(_ streams: [DashStream]) -> DashStream? { PlaybackOption.chooseVideo(streams, engine: engine.engineKind) }
  private func chooseAudio(_ streams: [DashStream], requested: Int? = nil) -> DashStream? {
    PlaybackOption.chooseAudio(streams, requested: requested, engine: engine.engineKind)
  }
  var selectedVideoStream:DashStream?{chooseVideo(dash?.video.filter{$0.id==quality} ?? [])}
  var selectedAudioStream:DashStream?{chooseAudio(dash?.audio ?? [],requested:audioID ?? preferences.overridden(audio:true))}
  var decoderName:String{if engine.engineKind == .mpv { return "mpv" }; return legacyBridge?.decodeRoute.rawValue ?? bridge?.decodeRoute.rawValue ?? "AVKit"}
  private var chosenAddresses:(cid:Int64,owner:String,video:URL,audio:URL?)?
  var addressGrant:ArchiveAddressGrant?{
    guard !isPreview,let cid=activeCID,let owner=activeVideoOwner else{return nil}
    if let legacyPlan, let parts = try? legacyPlan.body.parts {
      return .init(cid: cid, owner: owner, picture: parts.flatMap(\.originals), sound: [])
    }
    if let url=progressiveURL{return .init(cid:cid,owner:owner,picture:[url]+mirrors,sound:[])}
    guard let v=selectedVideoStream,!v.originals.isEmpty else{return nil}
    return .init(cid:cid,owner:owner,picture:v.originals,sound:selectedAudioStream?.originals ?? [])
  }
  func useAddress(_ v:URL,audio a:URL?,grant:ArchiveAddressGrant) async throws {
    guard !switching,let current=addressGrant,grant.key==current.key,
      case .issued=try current.pick(video:v.absoluteString,audio:a?.absoluteString ?? ""),
      (try await AccountJar.shared.current(.role(.video))?.id ?? "")==current.owner,
      addressGrant?.key==current.key else{throw ServiceError("视频或播放授权已更换")}
    let gen=generation
    if let plan = legacyPlan {
      guard a == nil else { throw ServiceError("此视频使用片段内的音轨") }
      let parts = try plan.body.parts
      guard let selected = parts.firstIndex(where: { $0.originals.contains(v) }) else { throw ServiceError("此地址不属于当前播放片段") }
      let updated = parts.enumerated().map { n, part in
        n == selected ? LegacyDURLBody.Part(url: part.url,
          backup_url: part.backup_url, order: part.order, length: part.length, selected: v) : part
      }
      if ready { wantsStart = engine.timeControlStatus != .paused }
      let body = plan.body
      try await activateLegacy(.init(body: .init(durl: updated, quality: body.quality,
        accept_quality: body.accept_quality, language: body.language, cur_language: body.cur_language, volume: body.volume),
        reference: plan.reference, owner: plan.owner, preview: plan.preview))
    }else if progressiveURL != nil{
      let stamp=UUID();switchStamp=stamp;switching=true;defer{if stamp==switchStamp{switching=false}}
      if ready{wantsStart=engine.timeControlStatus != .paused}
      try await open(v,owner:current.owner);qualityError=nil
    }else{
      let previous=chosenAddresses;chosenAddresses=(current.cid,current.owner,v,a)
      await changeQuality(quality)
      guard !Task.isCancelled,generation==gen else{throw CancellationError()}
      if let issue=qualityError{chosenAddresses=previous;throw ServiceError(issue)}
    }
  }
  var lineSample: [URL] {
    if let legacyPlan { return (try? legacyPlan.body.parts.first?.routes) ?? [] }
    return chooseVideo(dash?.video.filter { $0.id == quality } ?? [])?.originals
      ?? dash?.video.first?.originals ?? []
  }
  var lineReference: URL? { reference }
  var lineSampleOwner: String? { activeVideoOwner }
  func reloadPlayback()async{
    guard !switching,let owner=activeVideoOwner,let cid=activeCID else{return}
    if legacyPlan != nil { await changeLegacy(quality, language: spokenLanguage); return }
    if progressiveURL != nil && episodeSource == nil{await reloadLine();return}
    let gen=generation,stamp=UUID();switchStamp=stamp;switching=true;qualityError=nil;chosenAddresses=nil
    defer{if stamp==switchStamp{switching=false}}
    do{
      let fresh:DashFormats
      var freshClips:[EpisodeClip]?
      if let (episode,course)=episodeSource{
        if course{fresh=try await BiliAPI.shared.courseFormats(episode,language:spokenLanguage,expectedAccount:owner)}
        else{let reply=try await BiliAPI.shared.episodeFormats(episode,language:spokenLanguage,expectedAccount:owner);fresh=reply.0;freshClips=reply.1}
      }else if let bv=timeline.source?.bvid{
        fresh=try await BiliAPI.shared.formats(bv,cid:cid,language:spokenLanguage,expectedAccount:owner)
      }else{throw ServiceError("找不到当前视频")}
      try Task.checkCancellation();guard gen==generation,stamp==switchStamp,activeCID==cid,(try await AccountJar.shared.current(.role(.video))?.id ?? "")==owner else{return}
      let allowed=Set(fresh.video.filter(supportsVideo).map(\.id)).sorted(by:>)
      guard let requested=allowed.contains(quality) ? quality:preferences.preferredQuality(allowed) else{throw ServiceError("没有可播放的视频轨道")}
      if let freshClips{clips=freshClips}
      await changeQuality(requested,candidate:fresh)
    }catch{if !Task.isCancelled,stamp==switchStamp,generation==gen{qualityError=error.localizedDescription}}
  }
  func reloadLine() async {
    chosenAddresses=nil
    guard let expected = activeVideoOwner else { return }
    do {
      guard (try await AccountJar.shared.current(.role(.video))?.id ?? "") == expected else {
        throw ServiceError("取流账号已切换，请重新打开视频")
      }
    } catch { qualityError = error.localizedDescription; return }
    if legacyPlan != nil { await changeLegacy(quality, language: spokenLanguage); return }
    if (bridge != nil && bridge?.isProgressive != true) || (engine.engineKind == .mpv && progressiveURL == nil) || episodeSource != nil {
      if let q = availableQualities.contains(quality)
        ? quality : preferences.preferredQuality(availableQualities)
      {
        await changeQuality(q)
      }
      return
    }
    guard let bv = timeline.source?.bvid, let cid = activeCID else { return }
    let gen = generation
    let stamp = UUID()
    switchStamp = stamp
    switching = true
    defer { if switchStamp == stamp { switching = false } }
    do {
      let owner = expected
      let source = try await BiliAPI.shared.playback(bv, cid: cid, expectedAccount: owner)
      guard gen == generation, stamp == switchStamp, !Task.isCancelled else { return }
      if ready { wantsStart = engine.timeControlStatus != .paused }
      mirrors = Array(source.backups.prefix(3))
      progressivePreview = source.preview
      progressiveVolume = source.volume
      quality = source.quality
      qualityError = nil
      error = nil
      try await open(source.url, owner: owner)
    } catch {
      if gen == generation, stamp == switchStamp { qualityError = error.localizedDescription }
    }
  }
  private func adoptFormats(_ options: DashFormats) {
    dash = options
    spokenTracks = options.spoken
    spokenLanguage = options.selectedLanguage
    audioChoices = Set((options.audio ?? []).filter(supportsAudio).map(\.id)).sorted(
      by: >)
    availableQualities = Set(options.video.filter(supportsVideo).map(\.id)).sorted(
      by: >)
  }
  private func fetchLegacy(_ id: Int, language: String?, owner: String) async throws -> LegacyDURLPlan {
    if let (episode, course) = episodeSource {
      let info = try await BiliAPI.shared.playEpisodeInfo(episode, course: course, language: language,
        expectedAccount: owner, quality: id)
      _ = try info.legacy.parts
      guard let reference else { throw URLError(.badURL) }
      return .init(body: info.legacy, reference: reference, owner: owner, preview: episode.preview || info.preview)
    }
    guard let bv = timeline.source?.bvid, let cid = activeCID else { throw ServiceError("找不到当前视频") }
    return try await BiliAPI.shared.legacyPlayback(bv, cid: cid, quality: id, language: language, expectedAccount: owner)
  }
  private func activateLegacy(_ plan: LegacyDURLPlan, routes: [NativeVideoRoute]? = nil,
    manual: Bool = false) async throws {
    let stamp = UUID(), gen = generation
    switchStamp = stamp; switching = true
    defer { if switchStamp == stamp { switching = false } }
    let shouldPlay = ready ? engine.timeControlStatus != .paused : wantsStart
    if let mpv = engine as? MPVPlayer {
      let parts = try plan.body.parts
      let urls = try parts.map { part -> String in
        guard let url = part.routes.first else { throw ServiceError("没有可播放的视频地址") }
        let address = url.absoluteString
        let length = part.length.map { ",0," + String($0 / 1000) } ?? ""
        return "%\(address.utf8.count)%\(address)\(length)"
      }
      guard (try await AccountJar.shared.current(.role(.video))?.id ?? "") == plan.owner,
        gen == generation, stamp == switchStamp, !Task.isCancelled else { throw CancellationError() }
      clearItem()
      dash = nil
      legacyPlan = plan
      reference = plan.reference
      quality = plan.body.quality ?? 0
      availableQualities = Array(Set((plan.body.accept_quality ?? []) + [quality])).filter { $0 > 0 }.sorted(by: >)
      spokenTracks = plan.body.language?.ordered ?? []
      spokenLanguage = plan.body.cur_language
      audioChoices = []
      audioID = nil
      error = nil
      qualityError = nil
      mpvFallbacks = []
      if manual { preferences.record(quality, audio: false) }
      startMPV(mpv, video: "edl://!no_chapters;" + urls.joined(separator: ";"), audio: nil,
        reference: plan.reference, autoplay: shouldPlay, volume: plan.body.volume)
      return
    }
    let next = LegacyDURLPlayback(plan, routes: routes)
    do {
      let url = try await next.start()
      let owner = try await AccountJar.shared.current(.role(.video))?.id ?? ""
      guard owner == plan.owner, gen == generation, stamp == switchStamp, !Task.isCancelled else { throw CancellationError() }
      clearItem()
      dash = nil; legacyPlan = plan; legacyBridge = next
      reference = plan.reference; quality = plan.body.quality ?? 0
      availableQualities = Array(Set((plan.body.accept_quality ?? []) + [quality])).filter { $0 > 0 }.sorted(by: >)
      spokenTracks = plan.body.language?.ordered ?? []; spokenLanguage = plan.body.cur_language
      audioChoices = []; audioID = nil; mirrors = []; error = nil; qualityError = nil
      if manual { preferences.record(quality, audio: false) }
      observe(AVPlayerItem(url: url), autoplay: shouldPlay)
    } catch { next.close(); throw error }
  }
  private func changeLegacy(_ id: Int, language: String?, routes: [NativeVideoRoute]? = nil,
    manual: Bool = false) async {
    guard let owner = activeVideoOwner else { return }
    let gen = generation, stamp = UUID(), cid = activeCID
    switchStamp = stamp; switching = true; qualityError = nil
    defer { if switchStamp == stamp { switching = false } }
    do {
      let plan = try await fetchLegacy(id, language: language, owner: owner)
      guard gen == generation, switchStamp == stamp, activeCID == cid, !Task.isCancelled else { return }
      guard language == nil || plan.body.cur_language == language else { throw ServiceError("此语言音轨当前不可用") }
      try await activateLegacy(plan, routes: routes, manual: manual)
    } catch { if gen == generation, switchStamp == stamp, !Task.isCancelled { qualityError = error.localizedDescription } }
  }
  func changeLanguage(_ choice: SpokenTrack?) async {
    guard let cid = activeCID, choice?.id != spokenLanguage else { return }
    if legacyPlan != nil {
      guard choice == nil || spokenTracks.contains(where: { $0.id == choice?.id }) else { return }
      await changeLegacy(quality, language: choice?.id); return
    }
    let gen = generation
    let stamp = UUID()
    switchStamp = stamp
    switching = true
    qualityError = nil
    defer { if switchStamp == stamp { switching = false } }
    do {
      let uid=try await AccountJar.shared.current(.role(.video))?.id ?? ""
      guard uid==activeVideoOwner,choice==nil || spokenTracks.contains(where:{$0.id==choice?.id}) else{throw ServiceError("所选语言不属于当前播放授权")}
      var options: DashFormats
      if let (e, course) = episodeSource {
        if course {
          options = try await BiliAPI.shared.courseFormats(
            e, language: choice?.id, expectedAccount: uid)
        } else {
          options = try await BiliAPI.shared.episodeFormats(
            e, language: choice?.id, expectedAccount: uid
          ).0
        }
      } else if let bv = timeline.source?.bvid {
        options = try await BiliAPI.shared.formats(
          bv, cid: cid, language: choice?.id, expectedAccount: uid)
      } else {
        throw ServiceError("找不到当前视频")
      }
      try Task.checkCancellation()
      guard generation == gen, switchStamp == stamp, activeCID == cid else { return }
      guard (try await AccountJar.shared.current(.role(.video))?.id ?? "") == uid else {
        throw ServiceError("视频账号已切换")
      }
      guard choice == nil || options.selectedLanguage == choice?.id else {
        throw ServiceError("此语言音轨当前不可用")
      }
      if options.spoken.isEmpty { options.spoken = spokenTracks }
      let qs = Set(options.video.filter(supportsVideo).map(\.id))
      guard
        let target = qs.contains(quality) ? quality : preferences.preferredQuality(Array(qs)),
        (options.audio ?? []).contains(where: supportsAudio)
      else { throw ServiceError("此语言没有可播放的音轨") }
      guard gen == generation, switchStamp == stamp else { return }
      await changeQuality(target, candidate: options)
    } catch {
      if generation == gen, switchStamp == stamp, !Task.isCancelled {
        qualityError = error.localizedDescription
      }
    }
  }
  func changeQuality(
    _ id: Int, candidate: DashFormats? = nil, manualVideo: Bool = false, manualAudio: Int? = nil,
    decoderRoutes: [NativeVideoRoute]? = nil
  ) async {
    if candidate == nil, legacyPlan != nil {
      await changeLegacy(id, language: spokenLanguage, routes: decoderRoutes, manual: manualVideo); return
    }
    guard let dash = candidate ?? self.dash, let reference else { return }
    let candidates = dash.video.filter { $0.id == id }
    guard var stream = chooseVideo(candidates) else { return }
    var audio = chooseAudio(
      dash.audio ?? [], requested: manualAudio ?? audioID ?? preferences.overridden(audio: true))
    if let saved=chosenAddresses,let cid=activeCID,saved.cid==cid,saved.owner==activeVideoOwner,
       stream.originals.contains(saved.video),saved.audio.map({audio?.originals.contains($0)==true}) ?? (audio==nil){
      stream=(try? stream.selecting(saved.video)) ?? stream;audio=try? audio?.selecting(saved.audio)
    }else{chosenAddresses=nil}
    if audio == nil, dash.advertisedAudio {
      qualityError = "当前音轨格式不受支持"
      return
    }
    let shouldPlay =
      (!ready || engine.playbackItem == nil) ? wantsStart : engine.timeControlStatus != .paused
    let gen = generation
    let stamp = UUID()
    switchStamp = stamp
    switching = true
    qualityError = nil
    defer { if switchStamp == stamp { switching = false } }
    guard let activeVideoOwner else { return }
    if let mpv = engine as? MPVPlayer {
      do {
        guard (try await AccountJar.shared.current(.role(.video))?.id ?? "") == activeVideoOwner,
          gen == generation, stamp == switchStamp, !Task.isCancelled else { throw CancellationError() }
        let videoURLs = stream.routes(audio: false)
        let audioURLs = audio?.routes(audio: true) ?? []
        guard let videoURL = videoURLs.first, audio == nil || !audioURLs.isEmpty else {
          throw ServiceError("没有可播放的音视频地址")
        }
        clearItem()
        if let candidate { adoptFormats(candidate) }
        quality = id
        audioID = audio?.id
        if manualVideo { preferences.record(id, audio: false) }
        if let manualAudio, manualAudio == audio?.id { preferences.record(manualAudio, audio: true) }
        mpvFallbacks = Array(videoURLs.dropFirst().prefix(2)).map { ($0.absoluteString, audioURLs.first?.absoluteString) }
        mpvFallbacks += Array(audioURLs.dropFirst().prefix(2)).map { (videoURL.absoluteString, $0.absoluteString) }
        mirrors = []
        error = nil
        startMPV(mpv, video: videoURL.absoluteString, audio: audioURLs.first?.absoluteString,
          reference: reference, autoplay: shouldPlay, volume: dash.volume)
      } catch {
        if gen == generation, stamp == switchStamp, !Task.isCancelled { qualityError = error.localizedDescription }
      }
      return
    }
    let newBridge = DashBridge(reference: reference, decoding: decoderRoutes, expectedOwner: activeVideoOwner)
    do {
      let url = try await newBridge.start(
        video: stream,
        audio: audio, volume: dash.volume)
      guard gen == generation, stamp == switchStamp, !Task.isCancelled else {
        newBridge.close()
        return
      }
      clearItem()
      bridge = newBridge
      if let candidate { adoptFormats(candidate) }
      quality = id
      audioID = audio?.id
      if manualVideo { preferences.record(id, audio: false) }
      if let manualAudio, manualAudio == audio?.id { preferences.record(manualAudio, audio: true) }
      mirrors = []
      error = nil
      observe(AVPlayerItem(url: url), autoplay: shouldPlay)
    } catch {
      newBridge.close()
      if gen == generation && stamp == switchStamp { qualityError = error.localizedDescription }
    }
  }
  private func startMPV(_ mpv: MPVPlayer, video: String, audio: String?, reference: URL,
                        autoplay: Bool, volume: AudioMeasurements?) {
    let stamp = itemStamp
    let resume = seconds > 1 ? seconds : resumeAt
    wantsStart = autoplay
    mpv.load(video: video, audio: audio, reference: reference, start: max(0, resume),
      autoplay: autoplay, volume: volume)
    resumeAt = 0
    guard let item = mpv.currentItem else { return }
    mpv.onUpdate = { [weak self, weak mpv] in
      guard let self, let mpv, self.itemStamp == stamp else { return }
      if self.ready != mpv.playbackReady { self.ready = mpv.playbackReady }
      if mpv.playbackSize != .zero, self.pictureSize != mpv.playbackSize { self.pictureSize = mpv.playbackSize }
    }
    mpv.onEnd = { [weak self, weak item] in
      guard let self, let item else { return }
      Task { await self.finishMPV(item, stamp: stamp) }
    }
    mpv.onFailure = { [weak self, weak mpv] message in
      guard let self, let mpv, self.itemStamp == stamp else { return }
      self.ready = false
      if !self.mpvFallbacks.isEmpty {
        let next = self.mpvFallbacks.removeFirst()
        self.startMPV(mpv, video: next.0, audio: next.1, reference: reference,
          autoplay: self.wantsStart, volume: volume)
      } else { self.error = "播放失败：" + message }
    }
    PlaybackSleepTimer.shared.offerVideo(mpv, item: item, autoplay: autoplay) { [weak self, weak item] in
      guard let self, let item, self.engine.playbackItem === item, self.itemStamp == stamp else { return }
      self.wantsStart = false
      self.playing = false
      self.history.record(self.seconds, duration: self.duration, final: true)
    }
  }
  private func finishMPV(_ item: AnyObject, stamp: UUID) async {
    guard engine.playbackItem === item, itemStamp == stamp else { return }
    playing = false
    let slept = PlaybackSleepTimer.shared.didFinish(engine)
    if storyCID == activeCID, let pending = storyRequest { await pending.value }
    guard engine.playbackItem === item, itemStamp == stamp else { return }
    if storyCID == activeCID, !storyOptions.isEmpty || storyError != nil { storyEnded = true; return }
    if !slept {
      let mode = preferences.repeatMode
      var action = NextPlayback.end
      if mode == .one { action = .restart }
      else if mode != .pause, let next = queueEnd { action = await next(mode, { [weak self] in self?.itemStamp == stamp }) }
      guard itemStamp == stamp else { return }
      if action == .advanced { return }
      if action == .restart {
        let ok = await engine.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        if ok && itemStamp == stamp { seconds = 0; engine.play(); playing = true }
        return
      }
    }
    if itemStamp == stamp { finishedAt = UUID() }
  }
  private func observe(_ item: AVPlayerItem, autoplay: Bool) {
    VideoTransport.prepare(player, item)
    let stamp = itemStamp
    sizeObserver = item.observe(\.presentationSize, options: [.initial, .new]) {
      [weak self] item, _ in
      Task { @MainActor in
        guard let self, self.itemStamp == stamp else { return }
        let size = item.presentationSize
        if size.width > 0 && size.height > 0 && size != self.pictureSize { self.pictureSize = size }
      }
    }
    let resume = seconds > 1 ? seconds : resumeAt
    var handledReady = false
    observer = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      Task { @MainActor in
        guard let self, self.itemStamp == stamp else { return }
        switch item.status {
        case .readyToPlay:
          guard !handledReady else { return }; handledReady = true
          self.ready = true
          if resume > 0 {
            let length = item.duration.seconds
            self.seek(length.isFinite && length > 0 ? min(resume, max(0, length - 0.25)) : resume)
            self.resumeAt = 0
          }
          if autoplay && self.wantsStart { self.player.play() }
        case .failed: self.fail(item.error?.localizedDescription)
        default: break
        }
      }
    }
    failedNotice = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
    ) { [weak self] n in
      let message = (n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
        .localizedDescription
      Task { @MainActor in if self?.itemStamp == stamp { self?.fail(message) } }
    }
    player.replaceCurrentItem(with: item)
    PlaybackSleepTimer.shared.offerVideo(player, item: item, autoplay: autoplay) { [weak self, weak item] in
      guard let self, let item, self.player.currentItem === item, self.itemStamp == stamp else { return }
      self.wantsStart = false
      self.playing = false
      let time = self.player.currentTime().seconds
      if time.isFinite && !self.isPreview, let id = self.memoryID {
        PlaybackMemory.store(id, seconds: time, duration: self.duration)
        self.history.record(time, duration: self.duration, final: true)
      }
    }
    finishedNotice = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
    ) { [weak self, weak item] _ in
      Task { @MainActor in
        guard let self, let item, self.player.currentItem === item, self.itemStamp == stamp else {
          return
        }
        let slept = PlaybackSleepTimer.shared.didFinish(self.player)
        if self.storyCID == self.activeCID, let pending = self.storyRequest {
          await pending.value
          guard self.player.currentItem === item, self.itemStamp == stamp else { return }
        }
        if self.storyCID == self.activeCID, !self.storyOptions.isEmpty || self.storyError != nil {
          self.storyEnded = true
          return
        }
        if !slept {
          let mode = self.preferences.repeatMode
          var action = NextPlayback.end
          if mode == .one {
            action = .restart
          } else if mode != .pause, let next = self.queueEnd {
            action = await next(mode, { [weak self] in self?.itemStamp == stamp })
          }
          guard self.itemStamp == stamp else { return }
          if action == .advanced { return }
          if action == .restart {
            let ok = await self.player.seek(
              to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            if ok && self.itemStamp == stamp {
              self.seconds = 0
              self.player.play()
              self.playing = true
            }
            return
          }
        }
        if self.itemStamp == stamp { self.finishedAt = UUID() }
      }
    }
  }
  private static func stopProgressiveRetry(_ error: Error) -> Bool {
    if let e = error as? RangeHTTPStatus, [401, 403, 412, 429].contains(e.code) { return true }
    if let e = error as? LocalIndexIssue {
      switch e {
      case .encrypted, .external: return true
      default: break
      }
    }
    return error is CancellationError
  }
  private func fail(_ message: String?) {
    if recoveringItem == itemStamp { return }
    if ready { wantsStart = playing }
    ready = false
    if let old = legacyBridge {
      let remaining = old.takeRemainingDecoderRoutes()
      if !remaining.isEmpty {
        let gen = generation, item = itemStamp
        recoveringItem = item
        fallbackTask = Task {
          await changeLegacy(quality, language: spokenLanguage, routes: remaining)
          if gen == generation, itemStamp == item, !Task.isCancelled {
            recoveringItem = nil
            error = qualityError ?? message ?? "暂时无法播放这个视频"
          }
        }
      } else { error = message ?? "暂时无法播放这个视频" }
      return
    }
    if let url = progressiveURL, let owner = progressiveOwner {
      let gen = generation
      let original = itemStamp
      let request = switchStamp
      let old = bridge
      let routes = old?.takeRemainingDecoderRoutes() ?? [.direct, .copied, .software]
      recoveringItem = original
      fallbackTask = Task {
        @MainActor func current() -> Bool {
          gen == generation && original == itemStamp && request == switchStamp && !Task.isCancelled
        }
        defer { if itemStamp == original { recoveringItem = nil } }
        var last = message
        if !routes.isEmpty {
          do {
            try await open(url, owner: owner, indexed: true, routes: routes, previous: old)
            return
          } catch {
            guard current() else { return }
            if Self.stopProgressiveRetry(error) {
              self.error = error.localizedDescription
              return
            }
            last = error.localizedDescription
          }
        }
        // Mirrors are different files until fully re-indexed. Never reuse sample offsets across them.
        while current(), !mirrors.isEmpty {
          let next = mirrors.removeFirst()
          do {
            try await open(next, owner: owner)
            return
          } catch {
            guard current() else { return }
            if Self.stopProgressiveRetry(error) {
              self.error = error.localizedDescription
              return
            }
            last = error.localizedDescription
          }
        }
        guard current() else { return }
        if !triedDashFallback, let metadata = formatTask {
          triedDashFallback = true
          await metadata.value
          guard current() else { return }
          if let q = preferences.preferredQuality(availableQualities) { await changeQuality(q) }
        }
        if gen == generation, itemStamp == original, !Task.isCancelled {
          error = qualityError ?? last ?? "暂时无法播放这个视频"
        }
      }
      return
    }
    if let oldBridge = bridge {
      let routes = oldBridge.takeRemainingDecoderRoutes()
      if !routes.isEmpty {
        let gen = generation
        let item = itemStamp
        let q = quality
        recoveringItem = item
        fallbackTask = Task {
          guard gen == generation, itemStamp == item, !Task.isCancelled else { return }
          await changeQuality(q, decoderRoutes: routes)
          guard gen == generation, itemStamp == item, !Task.isCancelled else { return }
          recoveringItem = nil
          if bridge === oldBridge && !switching { error = qualityError ?? message ?? "可用解码线路均未能播放" }
        }
        return
      }
    }
    error = message ?? "暂时无法播放这个视频"
  }
  func reloadSubtitleCatalog(){
    guard let source=timeline.source,let bv=source.bvid,!bv.isEmpty else{return}
    let gen=generation;subtitleTask?.cancel()
    subtitleTask=Task{do{
      let owner=try await AccountJar.shared.current()?.id ?? ""
      let list=try await BiliAPI.shared.subtitles(bv,cid:source.cid,aid:source.aid,expectedAccount:owner)
      guard gen==generation,!Task.isCancelled else{return}
      await captions.offer(list,authorize:{guard (try await AccountJar.shared.current()?.id ?? "")==owner else{throw ServiceError("字幕账号已切换")}})
    }catch{if gen==generation && !Task.isCancelled{captions.issue=error.localizedDescription}}}
  }
  private func setupSystemMedia(_ title: SystemMediaTitle, step: ((Bool) -> Void)?) {
    systemMedia.bind(
      engine, title: title,
      play: { [weak self] in
        if let self, self.ready, self.engine.rate == 0 { self.toggle() }
      },
      pause: { [weak self] in
        self?.wantsStart = false
        self?.engine.pause()
        self?.playing = false
      }, seek: { [weak self] in self?.seek($0) }, next: step.map { change in { change(true) } },
      previous: step.map { change in { change(false) } })
  }
  func toggle() {
    VideoScenePause.shared.userIntent(engine)
    if engine.timeControlStatus != .paused {
      VideoInterruptionRecovery.shared.clear(engine)
      wantsStart = false
      engine.pause()
      playing = false
    } else {
      wantsStart = true
      ListenQueue.shared.stop()
      if duration > 0 && seconds >= duration - 0.4 { seek(0) }
      engine.play()
      playing = true
    }
  }
  func quickSeek(_ increment: Double, item: AnyObject) async {
    guard increment.isFinite else{return}
    let current=engine.currentTime().seconds
    await seekThenPlay((current.isFinite ? current:seconds)+increment,item:item)
  }
  func seekThenPlay(_ target:Double,item:AnyObject)async{
    guard ready,engine.playbackItem===item,target.isFinite,duration>0 else{return}
    let stamp=itemStamp,t=min(duration,max(0,target)), picture = PictureSession.shared(engine)
    let request = picture.beginSeek(item, to: t)
    pendingSeek = request
    defer {
      if pendingSeek == request { pendingSeek = nil }
      picture.finishSeek(request, for: item)
    }
    loadBullets(at: t)
    history.seeked(t)
    wantsStart = true; bridge?.seek(to: t); legacyBridge?.seek(to: t)
    let ok = await engine.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    guard ok, !Task.isCancelled, itemStamp == stamp, pendingSeek == request, wantsStart, engine.playbackItem === item else { return }
    seconds = t
    ListenQueue.shared.stop()
    engine.play(); playing = true
  }
  func seek(_ t: Double) {
    guard t.isFinite, let item = engine.playbackItem else { return }
    let picture = PictureSession.shared(engine), request = picture.beginSeek(item, to: t)
    pendingSeek = request
    loadBullets(at: t)
    history.seeked(t)
    bridge?.seek(to: t)
    legacyBridge?.seek(to: t)
    engine.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) {
      [weak self, weak item] _ in
      Task { @MainActor in
        guard let self, self.pendingSeek == request, let item, self.engine.playbackItem === item else { return }
        self.pendingSeek = nil
        picture.finishSeek(request, for: item)
      }
    }
    seconds = t
  }
  private func clearItem() {
    PictureSession.shared(engine).cancelSeek(for: engine.playbackItem)
    pendingSeek = nil
    itemStamp = UUID()
    progressiveURL = nil
    progressiveOwner = nil
    recoveringItem = nil
    ready = false
    sizeObserver?.invalidate()
    sizeObserver = nil
    pictureSize = .zero
    bridge?.close()
    bridge = nil
    legacyBridge?.close(); legacyBridge = nil; legacyPlan = nil
    observer?.invalidate()
    observer = nil
    if let finishedNotice {
      NotificationCenter.default.removeObserver(finishedNotice)
      self.finishedNotice = nil
    }
    if let failedNotice {
      NotificationCenter.default.removeObserver(failedNotice)
      self.failedNotice = nil
    }
    player.replaceCurrentItem(with: nil)
    if let mpv = engine as? MPVPlayer { mpv.onUpdate = nil; mpv.onEnd = nil; mpv.onFailure = nil; mpv.stop() }
    loader?.stop()
    loader = nil
  }
  func leavePlaybackPage() {
    if ready, let memoryID, let activeVideoOwner {
      let time = engine.currentTime().seconds
      pageReturn = (memoryID, activeVideoOwner, time.isFinite ? max(0, time) : seconds, playing)
    }
    stop()
  }
  private func restorePageOrStart(memory: String, owner: String, start: Double?, autoplay: Bool) {
    let returning = pageReturn.flatMap { $0.memory == memory && $0.owner == owner ? $0 : nil }
    pageReturn = nil
    memoryID = memory
    resumeAt = returning?.time ?? start ?? PlaybackMemory.read(memory)
    wantsStart = returning?.playing ?? autoplay
    if wantsStart { ListenQueue.shared.stop() }
  }
  func stop() {
    chosenAddresses=nil
    systemMedia.close()
    soundTask?.cancel()
    soundTask = nil
    progressivePreview = false
    progressiveVolume = nil
    hasPlayed = false
    storyEnded = false
    timeline.reset(nil)
    PlaybackSleepTimer.shared.unbind(engine)
    fallbackTask?.cancel()
    fallbackTask = nil
    triedDashFallback = false
    clips = []
    clipSkips = EpisodeSkipHistory()
    history.end(seconds, duration: duration)
    sponsorTask?.cancel()
    sponsorTask = nil
    sponsor = []
    sponsorError = nil
    toastTask?.cancel()
    toastTask = nil
    sponsorToast = nil
    sponsorVisits = SponsorVisits()
    segment = 0
    activeCID = nil
    activeVideoOwner = nil
    activeAID = nil
    segments = [:]
    if let memoryID { PlaybackMemory.store(memoryID, seconds: seconds, duration: duration) }
    memoryID = nil
    pendingPart = nil
    lastSaved = 0
    lastCaptionSpan = nil
    resumeAt = 0
    subtitleTask?.cancel()
    subtitleTask = nil
    captions.reset()
    generation = UUID()
    switchStamp = UUID()
    switching = false
    formatTask?.cancel()
    formatTask = nil
    dash = nil
    spokenTracks = []
    spokenLanguage = nil
    episodeSource = nil
    availableQualities = []
    audioID = nil
    audioChoices = []
    qualityError = nil
    bulletTask?.cancel()
    bulletTask = nil
    engine.pause()
    if let clock {
      engine.removeTimeObserver(clock)
      self.clock = nil
    }
    clearItem()
    seconds = 0
    duration = 0
    playing = false
    error = nil
    bulletError = nil
    bullets = []
    ownPosts.removeAll()
    sponsorDrafts.removeAll()
    mirrors = []
    reference = nil
    quality = 0
    revision = UUID()
  }
}
