import AVFoundation
import Combine
import SwiftUI

@MainActor final class NativeLivePlayback: ObservableObject {
  @Published private(set) var player: AVPlayer?
  private var onlyAudio = false
  private var audioRenderObserver: NSKeyValueObservation?
  @Published private(set) var issue: String?
  @Published private(set) var variants = [LiveVariant]()
  @Published private(set) var format: LiveFormat?
  @Published private(set) var line = 0
  @Published private(set) var currentHost: String?
  @Published private(set) var audioTracks: [LiveAudioTrack] = []
  @Published private(set) var selectedAudio: LiveAudioTrack?
  private var preferredAudio: LiveAudioTrack?, nativeAudio: AVMediaSelectionGroup?,
    nativeOptions: [String: AVMediaSelectionOption] = [:]
  var hasAudioOverride: Bool { preferredAudio != nil }
  func chooseAudio(_ choice: LiveAudioTrack?) {
    guard choice == nil || audioTracks.contains(where: { $0.id == choice?.id }) else { return }
    preferredAudio = choice
    if let item = player?.currentItem, let group = nativeAudio {
      if let choice, let opt = nativeOptions[choice.id] {
        item.select(opt, in: group)
        selectedAudio = choice
      } else {
        item.selectMediaOptionAutomatically(in: group)
        setCurrentAudio(item, group)
      }
    } else if let f = format {
      start(format: f, line: line)
    }
  }
  private func setCurrentAudio(_ item: AVPlayerItem, _ group: AVMediaSelectionGroup) {
    let current = item.currentMediaSelection.selectedMediaOption(in: group)
    selectedAudio = audioTracks.first(where: { nativeOptions[$0.id] == current })
  }
  private func directAudio(_ item: AVPlayerItem, stamp: UUID) async throws {
    guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible), epoch == stamp,
      player?.currentItem === item, !Task.isCancelled
    else {
      if preferredAudio != nil { throw LivePlaylistError.separateAudio }
      return
    }
    nativeAudio = group
    let ordered = group.options.enumerated().map { i, opt -> LiveAudioTrack in
      let lang = opt.extendedLanguageTag ?? opt.locale?.identifier
      let row = LiveAudioTrack(
        id: "native:" + String(i) + ":" + opt.displayName, title: opt.displayName, language: lang)
      nativeOptions[row.id] = opt
      return row
    }
    audioTracks = ordered
    if let wanted = preferredAudio {
      guard let match = LiveAudioTrack.match(wanted, in: ordered),
        let option = nativeOptions[match.id]
      else { throw LivePlaylistError.separateAudio }
      item.select(option, in: group)
    }
    setCurrentAudio(item, group)
  }

  private var room: Int64 = 0, epoch = UUID(), task: Task<Void, Never>?
  private weak var sessionPrefs: PlayerSessionPreferences?
  func setSessionPreferences(_ p: PlayerSessionPreferences) {
    sessionPrefs = p
    systemMedia.setTemporary(p.temporary ? p.controls : nil)
    if let player { VideoTransport.background(player, temporary: p.temporary ? p.background : nil) }
  }
  private let systemMedia = SystemMediaControls()
  private var roomMetadata = SystemMediaTitle(title: "直播", live: true)
  func updateRoom(_ id: Int64, title: String, artist: String?, cover: URL?) {
    guard room == id else { return }
    roomMetadata = .init(title: title, artist: artist, cover: cover, live: true)
    systemMedia.updateMetadata(roomMetadata)
  }
  private var bridge: LiveFLVBridge?
  private var decoderWatch: AnyCancellable?
  private var lastRestart: ContinuousClock.Instant?, restarts = 0
  init() {
    decoderWatch = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
      .map { _ in LiveDecoderSelection.settings }.prepend(LiveDecoderSelection.settings)
      .removeDuplicates().dropFirst()
      .debounce(for: .milliseconds(350), scheduler: DispatchQueue.main).sink { [weak self] _ in
        Task { @MainActor in
          guard let self, let f = self.format else { return }
          self.start(format: f, line: self.line)
        }
      }
  }
  var selected: LiveVariant? { variants.first { $0.id == format } }
  func open(_ source: LiveSource, room: Int64, audioOnly: Bool = false, title: String, artist: String? = nil, cover: URL? = nil) {
    stop()
    lastRestart = nil
    restarts = 0
    preferredAudio = nil
    self.room = room
    onlyAudio = audioOnly
    roomMetadata = .init(title: title, artist: artist, cover: cover, live: true)
    variants = source.variants
    guard source.live_status == 1 else {
      issue = "直播间尚未开播"
      return
    }
    guard let first = variants.first else {
      issue = "直播间没有可用的播放线路"
      return
    }
    let pref = LiveFormat(UserDefaults.standard.stringArray(forKey: "live.stream"))
    start(format: variants.first(where: { $0.id == pref })?.id ?? first.id, line: 0)
  }
  func choose(_ f: LiveFormat, _ line: Int = 0, persist: Bool = true) {
    guard variants.contains(where: { $0.id == f }) else { return }
    if persist { UserDefaults.standard.set(f.triple, forKey: "live.stream") }
    start(format: f, line: line)
  }
  func clearPreference() {
    UserDefaults.standard.removeObject(forKey: "live.stream")
    if let f = variants.first { start(format: f.id, line: 0) }
  }
  private func start(format first: LiveFormat, line firstLine: Int) {
    task?.cancel()
    epoch = UUID()
    clearPlayer()
    issue = nil
    let stamp = epoch
    let room = self.room
    let ordered = variants.filter { $0.id == first } + variants.filter { $0.id != first }
    task = Task {
      var attempted = false
      var reason: String?
      for variant in ordered {
        if preferredAudio != nil && variant.id.remux { continue }
        let routes: [NativeVideoRoute] = onlyAudio && !variant.id.remux ? [.direct] : LiveDecoderSelection.routes(variant.id)
        guard !routes.isEmpty else { continue }
        let origin = LiveCDNOrigin(UserDefaults.standard.string(forKey: "live.cdn"))
        for candidate in variant.routes(first: variant.id == first ? firstLine : 0, custom: origin)
        {
          let plans=routes.flatMap{route -> [(NativeVideoRoute,Bool)] in
            if !onlyAudio, route == .direct, !variant.id.remux,variant.id.proto=="http_hls",LiveDecoderSelection.family(variant.id) != nil {
              return [(route,true),(route,false)]
            }
            return [(route,false)]
          }
          var onlySystem=false
          for (route,clockCopy) in plans {
            if onlySystem && (route != .direct || clockCopy){continue}
            attempted = true
            let index = candidate.line
            guard epoch == stamp, !Task.isCancelled else { return }
            clearPlayer()
            format = variant.id
            line = index
            do {
              var url = candidate.url
              currentHost = url.host
              if variant.id.remux || route.converts || clockCopy {
                var source: LiveHLSFeed?
                if !variant.id.remux {
                  let origins = Set(([url] + variant.sources).compactMap(LiveHLSPlaylist.origin))
                  source = try await LiveHLSFeed.open(
                    url: url, room: room, codec: variant.id.codec, origins: origins,
                    selected: preferredAudio, preserveSystemSelection:clockCopy)
                }
                audioTracks = source?.choices ?? []
                selectedAudio = source?.selection
                let worker = try LiveFLVBridge(
                  url: url, room: room, route: route,
                  codec: LiveDecoderSelection.family(variant.id)?.1 ?? 0, playlist: source)
                bridge = worker
                url = try await worker.playable()
              }
              try Task.checkCancellation()
              guard epoch == stamp else { return }
              let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: [HTTPCookie]()])
              MediaCertificatePolicy.apply(to: asset)
              let item = AVPlayerItem(asset: asset)
              let p = AVPlayer(playerItem: item)
              if let sessionPrefs {
                VideoTransport.background(
                  p, temporary: sessionPrefs.temporary ? sessionPrefs.background : nil)
              }
              VideoTransport.prepare(p, item, live: true)
              let budget = MediaBufferHLS(item: item)
              defer { budget.stop() }
              try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
              PlaybackSleepTimer.shared.bind(p, item: item, live: true)
              systemMedia.bind(p, title: roomMetadata)
              player = p
              if onlyAudio {
                audioRenderObserver = item.observe(\.tracks, options:[.initial,.new]) { [weak self,weak item] _,_ in
                  Task { @MainActor in
                    guard let self, let item, self.epoch == stamp, self.player?.currentItem === item else { return }
                    for t in item.tracks where t.isEnabled && t.assetTrack?.mediaType == .video { t.isEnabled = false }
                  }
                }
              }
              if !variant.id.remux && route == .direct && !clockCopy {
                try await directAudio(item, stamp: stamp)
                guard epoch == stamp, !Task.isCancelled else { return }
              }
              var finished = false
              let notice = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
              ) { _ in Task { @MainActor in finished = true } }
              defer { NotificationCenter.default.removeObserver(notice) }
              p.play()
              let clock = ContinuousClock()
              var last = clock.now
              var position = Double.nan
              var hasMoved = false
              while epoch == stamp && !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(400))
                try Task.checkCancellation()
                guard epoch == stamp else { return }
                if let failure = bridge?.playlistFailure { throw failure }
                if item.status == .failed || finished {
                  if let code = item.errorLog()?.events.reversed().first(where: {
                    LiveAccessRefused.statuses.contains($0.errorStatusCode)
                  })?.errorStatusCode {
                    throw LiveAccessRefused(code: code)
                  }
                  break
                }
                let t = p.currentTime().seconds
                if t.isFinite && (!position.isFinite || abs(t - position) > 0.03) {
                  if position.isFinite { hasMoved = true }
                  last = clock.now
                  position = t
                }
                if item.status == .readyToPlay && p.timeControlStatus == .paused {
                  last = clock.now
                  continue
                }
                if last.duration(to: clock.now) > .seconds(hasMoved ? 18 : 16) { break }
              }
            } catch let e as LivePlaylistError {
              guard epoch == stamp, !Task.isCancelled else { return }
              if case .discontinuity = e {
                let now = ContinuousClock().now
                if lastRestart.map({ $0.duration(to: now) > .seconds(30) }) ?? true { restarts = 0 }
                if restarts < 2 {
                  restarts += 1
                  lastRestart = now
                  start(format: variant.id, line: index)
                  return
                }
              }
              switch e {
              case .protectedMedia:
                // Only the original system player may handle protected HLS. Never send keys or
                // encrypted payloads through the packet clock or fall back to a different codec.
                if clockCopy {onlySystem=true;continue}
                clearPlayer()
                issue = e.localizedDescription
                return
              case .denied(let code):
                clearPlayer()
                issue = LiveAccessRefused(code: code).localizedDescription
                return
              case .separateAudio: reason = e.localizedDescription
              default: break
              }
            } catch let refusal as LiveAccessRefused {
              guard epoch == stamp, !Task.isCancelled else { return }
              clearPlayer()
              issue = refusal.localizedDescription
              return
            } catch { if epoch != stamp || Task.isCancelled { return } }
          }
        }
      }
      if epoch == stamp && !Task.isCancelled {
        clearPlayer()
        issue = reason ?? (attempted ? "直播线路连接中断，请重新连接" : "此直播没有当前解码方式支持的线路")
      }
    }
  }
  private func clearPlayer() {
    audioRenderObserver = nil
    audioTracks = []
    selectedAudio = nil
    nativeAudio = nil
    nativeOptions = [:]
    systemMedia.close()
    if let p = player {
      PlaybackSleepTimer.shared.unbind(p)
      p.pause()
      p.replaceCurrentItem(with: nil)
    }
    player = nil
    bridge?.stop()
    bridge = nil
  }
  func stop() {
    epoch = UUID()
    task?.cancel()
    task = nil
    clearPlayer()
    issue = nil
    variants = []
    format = nil
    currentHost = nil
    line = 0
  }
}
