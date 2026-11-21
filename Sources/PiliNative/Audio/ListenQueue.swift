import AVFoundation
import MediaPlayer
import SwiftUI

struct ListenTrack: Codable, Identifiable, Equatable {
  let bvid: String, artist: String, cover: String
  var cid: Int64, title: String
  struct Part: Codable, Equatable { let cid: Int64, title: String }
  var archiveTitle: String? = nil
  var parts: [Part]? = nil
  func selecting(_ part: Part) -> Self {
    var result = self
    result.cid = part.cid
    result.title = (archiveTitle ?? title) + " · " + part.title
    return result
  }
  var origin: ListenOrigin? = nil, ownerID: Int64? = nil
  var episodeSource: ListenEpisodeReference? = nil
  var songID: Int64? = nil
  init(_ song: AudioSong, origin: ListenOrigin? = nil) {
    self.origin = origin
    ownerID = song.uid
    songID = song.id
    bvid = "au\(song.id)"
    cid = song.id
    title = song.title
    artist = song.author ?? ""
    cover = song.cover ?? ""
  }
  var id: String { "\(bvid):\(cid)" }
  init(_ video: Video, cid: Int64, origin: ListenOrigin? = nil) {
    self.origin = origin ?? video.ugc_season?.id.map { ListenOrigin.media($0, kind: 8) }
    ownerID = video.owner?.mid
    archiveTitle = video.title
    if let all = video.pages, all.count > 1 {
      var seen = Set<Int64>()
      parts = all.filter { $0.cid > 0 && seen.insert($0.cid).inserted }.map {
        Part(cid: $0.cid, title: $0.part)
      }
    }
    bvid = video.bvid
    self.cid = cid
    artist = video.owner?.name ?? ""
    cover = video.pic
    if let pages = video.pages, pages.count > 1, let part = pages.first(where: { $0.cid == cid }) {
      title = "\(video.title) · \(part.part)"
    } else {
      title = video.title
    }
  }
}
@MainActor final class ListenQueue: ObservableObject {
  static let shared = ListenQueue()
  @Published private(set) var tracks: [ListenTrack] = []
  @Published private(set) var current: ListenTrack?
  let progress = PlaybackProgress()
  private(set) var clock: Double {
    get { progress.seconds }
    set { progress.update(newValue, immediate: true) }
  }
  @Published private(set) var duration = 0.0
  @Published private(set) var playing = false
  @Published private(set) var loading = false
  @Published private(set) var issue: String?
  private var mode: AudioSequence {
    UserDefaults.standard.string(forKey: "listen.repeat").flatMap(AudioSequence.init(rawValue:))
      ?? .list
  }
  let catalog = ListenerCatalog()
  @Published private(set) var serviceQueue = false
  @Published private(set) var speed = 1.0
  @Published private(set) var media: ListenMedia?
  @Published private(set) var segments = [SponsorSegment]()
  @Published private(set) var skipHint: String?
  @Published private(set) var requestedSkip: SponsorSegment?
  @Published private(set) var segmentError: String?
  private var visits = SponsorVisits(), sponsorTask: Task<Void, Never>?
  @Published private(set) var mark: ListenMark?
  private var interruptionGate = ListenInterruptionGate()
  private var rateObserver: NSKeyValueObservation?
  private var sessionEvents: PlaybackSessionEvents?
  private let history = CloudWatchProgress()
  private var memoryID: String?
  private var lastSaved = 0
  private var owner: String?
  private var handed: (id: UUID, bv: String, cid: Int64, time: Double)?
  func handoff(_ t: ListenTrack, at clock: Double) -> UUID {
    let id = UUID()
    handed = nil
    start(t, at: clock)
    handed = (id, t.bvid, t.cid, clock)
    return id
  }
  func returnPosition(_ id: UUID, bvid: String, cid: Int64) -> Double? {
    guard let transfer = handed, transfer.id == id, transfer.bv == bvid, transfer.cid == cid else {
      return nil
    }
    handed = nil
    return current?.bvid == bvid && current?.cid == cid ? clock : transfer.time
  }
  private(set) var anchorID: String?
  private var partsTask: Task<Void, Never>?
  private var audioBridge: DashBridge?
  private var legacyBridge: LegacyDURLPlayback?
  private let player = AVPlayer()
  private var epoch = UUID(), scope = ""
  private var task: Task<Void, Never>?, loader: MediaLoader?, periodic: Any?,
    end: NSObjectProtocol?
  private var failedEnd: NSObjectProtocol?
  private var wantsSound = false
  private var itemObserver: NSKeyValueObservation?
  private let systemMedia = SystemMediaControls()
  private var restoreTask: Task<Void, Never>?
  private var restoreActions: [@MainActor () -> Void] = []
  private var queueWrite: Task<Void, Never>?
  private init() { player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible }
  func activate(account: String?) {
    let key = "audio.queue." + (account ?? "guest")
    guard key != scope else { return }
    restoreTask?.cancel(); restoreTask = nil
    restoreActions.removeAll()
    stop()
    handed = nil
    scope = key
    owner = account
    mark = nil; tracks = []
    let previousWrite = queueWrite
    restoreTask = Task {
      let saved = await Task.detached(priority: .userInitiated) {
        if let previousWrite { await previousWrite.value }
        let defaults = UserDefaults.standard
        let mark = defaults.data(forKey: key + ".position").flatMap {
          try? JSONDecoder().decode(ListenMark.self, from: $0)
        }
        let tracks = defaults.data(forKey: key).flatMap {
          try? JSONDecoder().decode([ListenTrack].self, from: $0)
        } ?? []
        return (mark, tracks)
      }.value
      guard !Task.isCancelled, scope == key else { return }
      mark = saved.0; tracks = saved.1
      restoreTask = nil
      let actions = restoreActions
      restoreActions.removeAll()
      for action in actions { action() }
    }
  }
  // Preserve actions made while the disk snapshot is loading, including a new queue item.
  private func afterRestore(_ action: @escaping @MainActor () -> Void) -> Bool {
    guard restoreTask != nil else { return false }
    restoreActions.append(action)
    return true
  }
  func videoAccountChanged(to id: String?) {
    guard current != nil else { return }
    // A loading track has not yet chosen between Listener and the video-account fallback.
    if media == nil || (media?.role == .video && (media?.grantOwner ?? "") != (id ?? "")) { stop() }
  }
  var playerVolume: Double { Double(player.volume) }
  func setVolume(_ v: Double) {
    guard v.isFinite else { return }
    objectWillChange.send()
    player.volume = Float(min(1, max(0, v)))
  }
  func setSpeed(_ v: Double) {
    guard v.isFinite else { return }
    speed = (min(2, max(0.5, v)) * 10).rounded() / 10
    player.defaultRate = Float(speed)
    if wantsSound && !loading && !interruptionGate.interrupted {
      player.playImmediately(atRate: Float(speed))
    }
    metadata()
  }
  func clearList() {
    if afterRestore({ self.clearList() }) { return }
    if !serviceQueue {
      stop()
      mark = nil
      UserDefaults.standard.removeObject(forKey: scope + ".position")
    }
    tracks = []
    save()
  }
  func continueListening() {
    if afterRestore({ self.continueListening() }) { return }
    guard let m = mark else { return }
    if m.sourceQueue {
      start(m.track, at: m.seconds)
    } else {
      start(m.track, at: m.seconds, within: m.anchor, local: true)
    }
  }
  private func storeMark() {
    guard !scope.isEmpty, PlaybackMemory.enabled, let t = current, clock.isFinite, clock >= 0 else {
      return
    }
    if duration > 0 && clock >= max(0, duration - 1) {
      mark = nil
      UserDefaults.standard.removeObject(forKey: scope + ".position")
      return
    }
    let m = ListenMark(track: t, anchor: anchorID, seconds: clock, sourceQueue: serviceQueue)
    if let d = try? JSONEncoder().encode(m) {
      mark = m
      UserDefaults.standard.set(d, forKey: scope + ".position")
    }
  }
  func hydrateSong(_ song: AudioSong) {
    guard let prior = current, prior.songID == song.id else { return }
    if catalog.records[prior.bvid] != nil { return }
    let rich = ListenTrack(song, origin: prior.origin)
    current = rich
    if let i = tracks.firstIndex(where: { $0.id == prior.id }) {
      tracks[i] = rich
      save()
    }
    if player.currentItem != nil { installCommands() }
  }
  func clearOthers() {
    if afterRestore({ self.clearOthers() }) { return }
    let keep = anchorID
    tracks.removeAll { $0.id != keep }
    save()
  }
  private func persist(final: Bool) {
    if let t = current, handed?.bv == t.bvid, handed?.cid == t.cid, clock.isFinite {
      handed?.time = clock
    }
    guard media?.preview != true, let current, let memoryID, clock.isFinite,
      clock < Double(Int32.max), duration.isFinite, duration > 0, clock >= 0
    else { return }
    if final || abs(Int(clock) - lastSaved) >= 8 {
      PlaybackMemory.store(memoryID, seconds: clock, duration: duration)
      lastSaved = Int(clock)
      storeMark()
    }
    if current.songID == nil { history.record(clock, duration: duration, final: final) }
  }
  func reloadSegments() {
    sponsorTask?.cancel()
    visits = SponsorVisits()
    requestedSkip = nil
    skipHint = nil
    segmentError = nil
    segments = []
    guard let t = current, t.songID == nil, UserDefaults.standard.bool(forKey: "sponsor.enabled")
    else { return }
    let gen = epoch
    sponsorTask = Task {
      do {
        let r = try await SponsorAPI().segments(t.bvid, t.cid)
        try Task.checkCancellation()
        guard gen == epoch else { return }
        let rules = SponsorRules.current()
        segments = r.filter { rules.mode($0) != 4 }
      } catch { if !Task.isCancelled && gen == epoch { segmentError = error.localizedDescription } }
    }
  }
  func skip(_ s: SponsorSegment) {
    guard s.valid else { return }
    requestedSkip = nil
    seek(s.segment[1])
    let rules = SponsorRules.current()
    if rules.toast { skipHint = "已跳过" + (s.detail?.title ?? "片段") }
    if rules.track, let api = try? SponsorAPI() { Task { try? await api.viewed(s.id) } }
  }
  private func save() {
    guard !scope.isEmpty, let finished = try? SleepExitFence.shared.enter() else { return }
    let rows = tracks, key = scope, previous = queueWrite
    queueWrite = Task.detached(priority: .utility) {
      defer { finished() }
      if let previous { await previous.value }
      if let data = try? JSONEncoder().encode(rows) { UserDefaults.standard.set(data, forKey: key) }
    }
  }
  func add(_ track: ListenTrack) {
    if afterRestore({ self.add(track) }) { return }
    if !tracks.contains(where: { $0.id == track.id }) {
      tracks.append(track)
      save()
    }
  }
  func remove(_ offsets: IndexSet) {
    if afterRestore({ self.remove(offsets) }) { return }
    let removed = offsets.contains { tracks.indices.contains($0) && tracks[$0].id == anchorID }
    tracks.remove(atOffsets: offsets)
    save()
    if removed && !serviceQueue { stop() }
  }
  func move(_ offsets: IndexSet, to: Int) {
    if afterRestore({ self.move(offsets, to: to) }) { return }
    tracks.move(fromOffsets: offsets, toOffset: to)
    save()
  }
  func seek(_ value: Double) {
    guard current != nil, value.isFinite else { return }
    clock = min(max(0, value), max(0, duration))
    audioBridge?.seek(to: clock)
    legacyBridge?.seek(to: clock)
    player.seek(to: CMTime(seconds: clock, preferredTimescale: 600))
    metadata()
  }
  func pause() {
    if afterRestore({ self.pause() }) { return }
    interruptionGate.invalidate()
    persist(final: true)
    wantsSound = false
    player.pause()
    playing = false
    metadata()
  }
  func resume() {
    if afterRestore({ self.resume() }) { return }
    interruptionGate.invalidate()
    VideoInterruptionRecovery.shared.clear()
    guard let t = current else {
      if let t = tracks.first { playRow(t, local: true) }
      return
    }
    do { try AVAudioSession.sharedInstance().setActive(true) }
    catch { pause(); issue = error.localizedDescription; return }
    wantsSound = true
    if loading { return }
    if issue != nil || player.currentItem == nil {
      start(t, at: clock, within: anchorID)
      return
    }
    if duration > 0 && clock >= duration - 0.3 { seek(0) }
    if let item = player.currentItem {
      bindSleep(item)
    }
    interruptionGate.invalidate()
    player.playImmediately(atRate: Float(speed))
    playing = true
    metadata()
  }
  func step(_ direction: Int, automatic: Bool = false) {
    guard let t = current, let anchor = anchorID else { return }
    navigate(direction, automatic: automatic, t: t, anchor: anchor, mayFetch: true)
  }
  private func navigate(
    _ direction: Int, automatic: Bool, t: ListenTrack, anchor: String, mayFetch: Bool
  ) {
    let remote =
      serviceQueue && (catalog.usesListener || catalog.origin?.source == 1)
      && catalog.tracks.contains(where: { $0.bvid == t.bvid })
    let rows = remote ? catalog.tracks : tracks
    guard let index = rows.firstIndex(where: { remote ? $0.bvid == t.bvid : $0.id == anchor })
    else { return }
    let active = catalog.tracks.first(where: { $0.bvid == t.bvid }) ?? t
    let parts = (t.parts ?? active.parts) ?? []
    let part = parts.firstIndex { $0.cid == t.cid }
    if remote && mayFetch
      && !(automatic
        && (mode == .pause || mode == .one
          || (mode != .shuffle && direction == 1 && part.map { $0 + 1 < parts.count } == true)))
      && ((direction == 1 && index == rows.count - 1 && catalog.after != nil)
        || (direction == -1 && index == 0 && catalog.before != nil))
    {
      let gen = epoch
      Task {
        await catalog.load(direction > 0 ? .next : .previous)
        guard epoch == gen else { return }
        navigate(direction, automatic: automatic, t: t, anchor: anchor, mayFetch: false)
      }
      return
    }
    switch mode.action(
      automatic: automatic, direction: direction, row: index, count: rows.count, part: part,
      parts: parts.count)
    {
    case .stop: pause()
    case .unchanged: break
    case .current:
      if player.currentItem?.status == .readyToPlay {
        seek(0)
        resume()
      } else {
        start(t, at: 0, within: anchor)
      }
    case .part(let n):
      guard parts.indices.contains(n) else { return }
      var target = t
      target.parts = parts
      target = target.selecting(parts[n])
      let nextAnchor =
        (!remote && rows.indices.contains(index + 1) && rows[index + 1].id == target.id)
        ? target.id : anchor
      start(target, at: 0, within: nextAnchor)
    case .row(let n): start(rows[n], at: 0, within: rows[n].id)
    case .shuffled:
      if let row = rows.enumerated().filter({ $0.offset != index }).randomElement()?.element {
        start(row, at: 0, within: row.id)
      }
    }
  }
  func playRow(_ t: ListenTrack, local: Bool, part: ListenTrack.Part? = nil) {
    let next = part.map { t.selecting($0) } ?? t
    if current?.id == next.id && local == !serviceQueue { return }
    if local { start(next, within: t.id, local: true) } else { start(next, at: 0, within: t.id) }
  }
  func start(
    _ track: ListenTrack, at offset: Double? = nil, within anchor: String? = nil,
    local: Bool = false
  ) {
    if afterRestore({ self.start(track, at: offset, within: anchor, local: local) }) { return }
    VideoInterruptionRecovery.shared.clear()
    if anchor == nil { add(track) }
    resetPlayer()
    if local {
      serviceQueue = false
      catalog.open(track, owner: owner)
    } else if anchor != nil && !serviceQueue {
      catalog.open(track, owner: owner)
    } else if anchor == nil {
      serviceQueue = true
      catalog.open(track, owner: owner)
    }
    anchorID = anchor ?? track.id
    current = track
    wantsSound = true
    loading = true
    lastSaved = 0
    let mem =
      track.songID.map { "audio:" + PlaybackMemory.id($0, account: owner) }
      ?? PlaybackMemory.id(track.cid, account: owner)
    memoryID = mem
    let previous = offset ?? PlaybackMemory.read(mem)
    let startAt = previous.isFinite && previous >= 0 && previous < Double(Int32.max) ? previous : 0
    let gen = epoch
    PlaybackSleepTimer.shared.bindPending(player) { [weak self] in
      guard let self, self.epoch == gen else { return }
      self.pause()
    }
    clock = startAt
    player.defaultRate = Float(speed)
    catalog.hydrated = { [weak self] in self?.hydrateCurrent() }
    monitorAudio(epoch: epoch)
    reloadSegments()
    let token = epoch
    if track.songID == nil, track.archiveTitle == nil {
      partsTask = Task {
        guard let archive = try? await BiliAPI.shared.detail(track.bvid), !Task.isCancelled,
          epoch == token
        else { return }
        let richer = ListenTrack(archive, cid: track.cid, origin: track.origin)
        current = richer
        if let i = tracks.firstIndex(where: { $0.id == track.id }) {
          tracks[i] = richer
          save()
        }
      }
    }
    task = Task { [weak self] in
      guard let self else { return }
      do {
        let state = try await AccountJar.shared.presentedState()
        guard state.active == owner else { throw ServiceError("账号已切换") }
        let source = try await BiliAPI.shared.listeningMedia(
          track, owner: owner, videoOwner: state.owner(.role(.video)))
        guard epoch == token, !Task.isCancelled else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        if wantsSound { try session.setActive(true) }
        media = source
        if track.songID == nil {
          var fields = ["cid": String(track.cid), "type": "3", "bvid": track.bvid]
          if let ep = track.episodeSource {
            fields["type"] = ep.course ? "10" : "4"
            fields["epid"] = String(ep.id)
            if ep.course {
              fields["aid"] = track.objectID.map(String.init)
              fields["bvid"] = nil
            }
          }
          if !source.preview { history.begin(uid: state.owner(.role(.heartbeat)), fields: fields) }
        }
        var bridgeURL: URL?
        if let plan = source.legacy {
          let bridge = LegacyDURLPlayback(plan, audioOnly: true)
          do {
            let url = try await bridge.start()
            try Task.checkCancellation(); try await source.authorize()
            guard token == epoch else { throw CancellationError() }
            legacyBridge = bridge; bridgeURL = url
          } catch { bridge.close(); throw error }
        } else if let stream = source.stream, AudioSegment.supports(stream.codecs),
          !AudioFilterChoice.current(source.volume).isEmpty,
          ByteSpan(stream.SegmentBase.Initialization) != nil,
          ByteSpan(stream.SegmentBase.indexRange) != nil
        {
          let bridge = DashBridge(
            reference: source.reference, expectedOwner: source.grantOwner ?? "",
            expectedRole: source.role)
          do {
            let url = try await bridge.startAudio(stream, volume: source.volume)
            try Task.checkCancellation()
            guard token == epoch else { throw CancellationError() }
            audioBridge = bridge
            bridgeURL = url
          } catch {
            bridge.close()
            throw error
          }
        }
        try openLine(
          source.urls[...], reference: source.reference, offset: startAt, epoch: token,
          localAudio: bridgeURL)
        periodic = player.addPeriodicTimeObserver(
          forInterval: .init(seconds: 1, preferredTimescale: 1), queue: .main
        ) { [weak self] t in
          Task { @MainActor in
            guard let self, self.epoch == token, !self.loading, t.seconds.isFinite else { return }
            self.clock = t.seconds
            let playing = self.player.rate > 0
            if self.playing != playing { self.playing = playing }
            if self.playing {
              self.persist(final: false)
            }
            if playing, !self.segments.isEmpty {
              let rules = SponsorRules.current()
              if let seg = self.visits.next(self.segments, time: t.seconds, rules: rules) {
                self.skip(seg)
              }
              let request = self.segments.first {
                $0.valid && rules.mode($0) == 2 && $0.segment[0] <= t.seconds
                  && t.seconds < $0.segment[1]
              }
              if request?.id != self.requestedSkip?.id { self.requestedSkip = request }
            }
            self.metadata()
          }
        }
        installCommands()
      } catch {
        if epoch == token && !Task.isCancelled {
          loading = false
          issue = error.localizedDescription
        }
      }
    }
  }
  private func bindSleep(_ item: AVPlayerItem) {
    let gen = epoch
    PlaybackSleepTimer.shared.bind(
      player, item: item, handlesEnd: true,
      onSleep: { [weak self, weak item] in
        guard let self, let item, self.epoch == gen, self.player.currentItem === item else {
          return
        }
        self.pause()
      })
  }
  private func hydrateCurrent() {
    guard let t = current, let o = t.defaultOrigin, let row = catalog.records[t.bvid],
      var rich = ListenTrack(row, context: o, selected: t.cid)
    else { return }
    rich.episodeSource = t.episodeSource
    if t.episodeSource != nil { rich.title = t.title }
    current = rich
    if let i = tracks.firstIndex(where: { $0.id == t.id }) {
      tracks[i] = rich
      save()
    }
    if player.currentItem != nil { installCommands() }
  }
  private func clearLine() {
    itemObserver?.invalidate()
    itemObserver = nil
    for token in [end, failedEnd].compactMap({ $0 }) {
      NotificationCenter.default.removeObserver(token)
    }
    end = nil
    failedEnd = nil
    player.replaceCurrentItem(with: nil)
    loader?.stop()
    loader = nil
  }
  private func openLine(
    _ lines: ArraySlice<URL>, reference: URL, offset: Double, epoch token: UUID,
    localAudio: URL? = nil
  )
    throws
  {
    guard let url = lines.first else { throw ServiceError("没有可用的音频线路") }
    clearLine()
    loading = true
    clock = offset
    let item: AVPlayerItem
    if let localAudio {
      item = AVPlayerItem(url: localAudio)
    } else {
      let selected = media
      let l = MediaLoader(
        url: url, reference: reference, audioOnly: true,
        authorize: { try await selected?.authorize() })
      loader = l
      item = l.makeItem()
      ItemAudioGain.attach(item)
    }
    player.replaceCurrentItem(with: item)
    @MainActor func failed(_ owner: ListenQueue, message: String?) {
      guard owner.epoch == token, owner.player.currentItem === item else { return }
      let at = owner.loading ? offset : owner.clock
      if lines.count > 1 && localAudio == nil {
        try? owner.openLine(lines.dropFirst(), reference: reference, offset: at, epoch: token)
      } else {
        owner.clearLine()
        owner.issue = message ?? "无法播放音轨"
        owner.loading = false
        owner.pause()
      }
    }
    itemObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      Task { @MainActor in
        guard let self, self.epoch == token, self.player.currentItem === item else { return }
        if item.status == .failed {
          failed(self, message: item.error?.localizedDescription)
        } else if item.status == .readyToPlay && self.loading {
          let d = item.duration.seconds
          self.duration = d.isFinite ? d : 0
          if offset > 0 && self.duration > 0 {
            let target = CMTime(seconds: min(offset, self.duration), preferredTimescale: 600)
            _ = await self.player.seek(to: target)
            guard self.epoch == token, self.player.currentItem === item else { return }
          }
          self.loading = false
          self.bindSleep(item)
          if self.wantsSound {
            self.player.playImmediately(atRate: Float(self.speed))
            self.playing = true
          }
          self.metadata()
        }
      }
    }
    failedEnd = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
    ) { [weak self] n in
      let message = (n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
        .localizedDescription
      Task { @MainActor in if let self { failed(self, message: message) } }
    }
    end = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.epoch == token, self.player.currentItem === item else { return }
        if PlaybackSleepTimer.shared.didFinish(self.player) {
          self.pause()
          return
        }
        self.step(1, automatic: true)
      }
    }
  }
  private func installCommands() {
    if let t = current {
      systemMedia.bind(
        player, title: .init(title: t.title, artist: t.artist, cover: httpsURL(t.cover)), video: false,
        play: { [weak self] in self?.resume() }, pause: { [weak self] in self?.pause() },
        seek: { [weak self] in self?.seek($0) }, next: { [weak self] in self?.step(1) },
        previous: { [weak self] in self?.step(-1) })
    }
  }
  private func monitorAudio(epoch gen: UUID) {
    rateObserver = player.observe(\.rate, options: [.new]) { [weak self] p, _ in
      Task { @MainActor in
        guard let self, self.epoch == gen else { return }
        self.playing = p.rate > 0
        self.metadata()
      }
    }
    sessionEvents = PlaybackSessionEvents { [weak self] event in
      guard let self, self.epoch == gen else { return }
      switch event {
      case .systemInterruption:
        self.interruptionGate.begin(active: self.wantsSound)
        self.persist(final: true)
        self.wantsSound = false
        self.player.pause()
        self.playing = false
        self.metadata()
      case let .recommendation(allowed):
        if self.interruptionGate.finish(shouldResume: allowed) { self.resume() }
      case .outputLost:
        self.pause()
      case .appInactive:
        self.cancelInterruptedPlay()
      }
    }
  }
  func yieldPlaybackToVideo() {
    if current != nil && (interruptionGate.interrupted || wantsSound || playing) { pause() }
  }
  private func cancelInterruptedPlay() {
    if interruptionGate.interrupted { pause() }
  }
  private func metadata() { systemMedia.publish() }
  func stop() {
    if afterRestore({ self.stop() }) { return }
    resetPlayer()
    catalog.reset()
    serviceQueue = false
  }
  private func resetPlayer() {
    legacyBridge?.close(); legacyBridge = nil
    audioBridge?.close()
    audioBridge = nil
    persist(final: true)
    history.end(clock, duration: duration)
    memoryID = nil
    media = nil
    sponsorTask?.cancel()
    sponsorTask = nil
    segments = []
    requestedSkip = nil
    skipHint = nil
    segmentError = nil
    interruptionGate.invalidate()
    rateObserver?.invalidate()
    rateObserver = nil
    sessionEvents?.close()
    sessionEvents = nil
    let owned = systemMedia.ownsSession
    systemMedia.close()
    partsTask?.cancel()
    partsTask = nil
    anchorID = nil
    PlaybackSleepTimer.shared.unbind(player)
    epoch = UUID()
    task?.cancel()
    task = nil
    player.pause()
    clearLine()
    wantsSound = false
    if let periodic { player.removeTimeObserver(periodic) }
    periodic = nil
    if current != nil && owned {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    current = nil
    clock = 0
    duration = 0
    issue = nil
    loading = false
    playing = false
  }
}
