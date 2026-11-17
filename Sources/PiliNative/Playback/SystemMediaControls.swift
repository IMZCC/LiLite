import AVKit
import Combine
import MediaPlayer
import SwiftUI

struct SystemMediaTitle {
  let title: String
  var artist: String? = nil
  var cover: URL? = nil
  var live = false
}

@MainActor final class SystemMediaControls: ObservableObject {
  static let key = "play.systemMedia"
  private static weak var current: SystemMediaControls?
  private final class Previous {
    weak var owner: SystemMediaControls?
    init(_ owner: SystemMediaControls) { self.owner = owner }
  }
  private static var history = [Previous]()
  private var policyEnabled: Bool {
    temporaryEnabled ?? (UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true)
  }
  private weak var player: (any PlaybackEngine)?
  private var title = SystemMediaTitle(title: "")
  private var play: (() -> Void)?, pause: (() -> Void)?, seek: ((Double) -> Void)?
  private var next: (() -> Void)?, previous: (() -> Void)?
  private var rateObservation: AnyCancellable?
  private var defaultsObservation: NSObjectProtocol?
  private var timer: Any?, targets: [(MPRemoteCommand, Any)] = []
  private var coverTask: Task<Void, Never>?, artwork: MPMediaItemArtwork?
  private var stamp = UUID(), commands = UUID(), enabled = true
  private var temporaryEnabled: Bool?
  func setTemporary(_ value: Bool?) {
    temporaryEnabled = value
    let next = value ?? (UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true)
    if next != enabled {
      enabled = next
      updateOwnership()
    }
  }
  var ownsSession: Bool { Self.current === self }

  func bind(
    _ player: any PlaybackEngine, title: SystemMediaTitle, video: Bool = true,
    play: (() -> Void)? = nil, pause: (() -> Void)? = nil,
    seek: ((Double) -> Void)? = nil, next: (() -> Void)? = nil, previous: (() -> Void)? = nil
  ) {
    let held = ownsSession && self.player === player
    close(reselect: !held)
    self.player = player
    if video { VideoInterruptionRecovery.shared.register(player) }
    self.title = title
    self.play = play ?? { [weak player] in player?.play() }
    self.pause = pause ?? { [weak player] in player?.pause() }
    self.seek =
      title.live
      ? nil
      : (seek ?? { [weak player] seconds in
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
      })
    self.next = next
    self.previous = previous
    let token = stamp
    enabled = temporaryEnabled ?? (UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true)
    if held && enabled { adopt() }
    rateObservation = player.statePublisher.sink { [weak self] _ in
      Task { @MainActor in
        guard let self, self.stamp == token else { return }
        self.updateOwnership()
      }
    }
    defaultsObservation = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.stamp == token else { return }
        let value =
          self.temporaryEnabled ?? (UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true)
        guard value != self.enabled else { return }
        self.enabled = value
        self.updateOwnership()
      }
    }
    timer = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 2, preferredTimescale: 1), queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.stamp == token else { return }
        self.publish()
      }
    }
  }
  private func updateOwnership() {
    guard let player, enabled else {
      let wasCurrent = ownsSession
      resign()
      if wasCurrent { Self.restorePrevious() }
      return
    }
    guard player.rate > 0 || ownsSession else { return }
    if !ownsSession { adopt() }
    else { publish() }
  }
  private func adopt() {
    enabled = policyEnabled
    Self.history.removeAll { $0.owner == nil || $0.owner === self }
    Self.history.append(Previous(self))
    Self.current?.resign()
    Self.current = self
    install()
    refreshCover()
    publish()
  }
  private static func restorePrevious() {
    guard current == nil else { return }
    history.removeAll { $0.owner == nil }
    // Restore controls, not playback. A prefetched item has never owned the controls.
    let previous = history.reversed().compactMap(\.owner).first {
      $0.policyEnabled && $0.player?.playbackItem != nil
    }
    previous?.adopt()
  }
  func updateMetadata(_ value: SystemMediaTitle) {
    let changed = title.cover != value.cover
    title = value
    if changed && ownsSession { refreshCover() }
    publish()
  }
  private func refreshCover() {
    coverTask?.cancel(); coverTask = nil; artwork = nil
    if let url = title.cover {
        let token = stamp
        coverTask = Task { [weak self] in
          guard
            let pic = try? await ArtworkStore.shared.image(
              url, pixels: 480, maximum: 3 * 1024 * 1024),
            !Task.isCancelled, let self, self.stamp == token, self.title.cover == url, self.ownsSession
          else { return }
          self.artwork = MPMediaItemArtwork(boundsSize: pic.size) { _ in pic }
          self.publish()
        }
      }
  }
  private func install() {
    commands = UUID()
    let binding = commands
    let c = MPRemoteCommandCenter.shared()
    func action(
      _ command: MPRemoteCommand, enabled: Bool = true,
      _ f: @escaping @MainActor (SystemMediaControls) -> Void
    ) {
      command.isEnabled = enabled
      guard enabled else { return }
      let key = command.addTarget { [weak self] _ in
        Task { @MainActor in
          guard let self, self.commands == binding, self.ownsSession else { return }
          VideoScenePause.shared.userIntent(self.player)
          f(self)
        }
        return .success
      }
      targets.append((command, key))
    }
    action(c.playCommand) { $0.play?() }
    action(c.pauseCommand) { owner in
      if let p = owner.player { VideoInterruptionRecovery.shared.clear(p) }
      owner.pause?()
    }
    action(c.togglePlayPauseCommand) { owner in
      if (owner.player?.rate ?? 0) != 0 { owner.pause?() } else { owner.play?() }
    }
    action(c.nextTrackCommand, enabled: next != nil) { $0.next?() }
    action(c.previousTrackCommand, enabled: previous != nil) { $0.previous?() }
    c.skipForwardCommand.preferredIntervals = [10]
    c.skipBackwardCommand.preferredIntervals = [10]
    action(c.skipForwardCommand, enabled: seek != nil) { $0.move(10) }
    action(c.skipBackwardCommand, enabled: seek != nil) { $0.move(-10) }
    c.changePlaybackPositionCommand.isEnabled = seek != nil
    if seek != nil {
      let cmd = c.changePlaybackPositionCommand
      let key = cmd.addTarget { [weak self] e in
        guard let seconds = (e as? MPChangePlaybackPositionCommandEvent)?.positionTime,
          seconds.isFinite
        else { return .commandFailed }
        Task { @MainActor in
          guard let self, self.commands == binding, self.ownsSession else { return }
          self.jump(seconds)
        }
        return .success
      }
      targets.append((cmd, key))
    }
  }
  private func move(_ delta: Double) {
    guard let here = player?.currentTime().seconds, here.isFinite else { return }
    jump(here + delta)
  }
  private func jump(_ position: Double) {
    guard let duration = player?.playbackDuration, duration.isFinite, duration > 0
    else { return }
    seek?(min(duration, max(0, position)))
  }
  func publish() {
    guard ownsSession, enabled, let player else { return }
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: title.title,
      MPNowPlayingInfoPropertyIsLiveStream: title.live,
      MPNowPlayingInfoPropertyPlaybackRate: player.rate,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: player.defaultRate,
    ]
    info[MPMediaItemPropertyArtist] = title.artist
    info[MPMediaItemPropertyArtwork] = artwork
    if !title.live {
      let d = Optional(player.playbackDuration)
      let t = player.currentTime().seconds
      if let d, d.isFinite && d > 0 { info[MPMediaItemPropertyPlaybackDuration] = d }
      if t.isFinite { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, t) }
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }
  private func resign() {
    guard ownsSession else { return }
    Self.current = nil
    commands = UUID()
    coverTask?.cancel()
    coverTask = nil
    artwork = nil
    for (command, key) in targets { command.removeTarget(key) }
    targets.removeAll()
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }
  static func clearForExit() {
    let owners = history.compactMap(\.owner)
    for owner in owners { owner.player?.pause(); owner.close(reselect: false) }
  }
  func close() { close(reselect: true) }
  private func close(reselect: Bool) {
    let wasCurrent = ownsSession
    resign()
    Self.history.removeAll { $0.owner == nil || $0.owner === self }
    stamp = UUID()
    rateObservation?.cancel()
    rateObservation = nil
    if let defaultsObservation { NotificationCenter.default.removeObserver(defaultsObservation) }
    defaultsObservation = nil
    if let timer { player?.removeTimeObserver(timer) }
    timer = nil
    player = nil
    play = nil
    pause = nil
    seek = nil
    next = nil
    previous = nil
    if wasCurrent && reselect { Self.restorePrevious() }
  }
}

struct OutputRouteButton: UIViewRepresentable {
  var video = true
  @Environment(\.isEnabled) private var enabled
  func makeUIView(context: Context) -> AVRoutePickerView {
    let v = AVRoutePickerView()
    v.prioritizesVideoDevices = video
    v.accessibilityLabel = video ? "选择播放设备" : "选择音频输出"
    v.isUserInteractionEnabled = enabled
    v.alpha = enabled ? 1 : 0.35
    return v
  }
  func updateUIView(_ v: AVRoutePickerView, context: Context) {
    v.prioritizesVideoDevices = video
    v.isUserInteractionEnabled = enabled
    v.alpha = enabled ? 1 : 0.35
  }
}
