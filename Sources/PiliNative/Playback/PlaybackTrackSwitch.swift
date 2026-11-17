import AVFoundation
import SwiftUI

/// The switch belongs to the player, so closing the menu cannot silently reenable the picture.
@MainActor private final class PlaybackTrackSwitchState: ObservableObject {
  @Published private(set) var available = false
  @Published private(set) var audioOnly = false
  private static var key: UInt8 = 0
  private weak var player: AVPlayer?
  private weak var item: AVPlayerItem?
  private var observations: [NSKeyValueObservation] = []
  private var current: NSKeyValueObservation?
  private var disabled: [AVPlayerItemTrack] = []

  static func shared(_ player: AVPlayer) -> PlaybackTrackSwitchState {
    if let value = objc_getAssociatedObject(player, &key) as? PlaybackTrackSwitchState {
      return value
    }
    let value = PlaybackTrackSwitchState(player)
    objc_setAssociatedObject(player, &key, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return value
  }
  private init(_ player: AVPlayer) {
    self.player = player
    current = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
      Task { @MainActor [weak self] in self?.bind() }
    }
  }
  private func bind() {
    guard item !== player?.currentItem else { return }
    observations.removeAll()
    for track in disabled { track.isEnabled = true }
    disabled.removeAll()
    audioOnly = false
    available = false
    item = player?.currentItem
    guard let item else { return }
    observations = [
      item.observe(\.tracks, options: [.initial, .new]) { [weak self] _, _ in
        Task { @MainActor [weak self] in self?.apply() }
      },
      item.observe(\.status, options: [.new]) { [weak self] _, _ in
        Task { @MainActor [weak self] in self?.apply() }
      },
    ]
  }
  private func apply() {
    guard let item, item === player?.currentItem else { return }
    let videos = item.tracks.filter { $0.assetTrack?.mediaType == .video }
    let audio = item.tracks.contains { $0.isEnabled && $0.assetTrack?.mediaType == .audio }
    available = item.status == .readyToPlay && !videos.isEmpty && audio
    if audioOnly && !available { audioOnly = false }
    if audioOnly {
      for track in videos where track.isEnabled {
        if !disabled.contains(where: { $0 === track }) { disabled.append(track) }
        track.isEnabled = false
      }
    } else {
      for track in disabled { track.isEnabled = true }
      disabled.removeAll()
    }
  }
  func set(_ enabled: Bool) {
    guard available, item === player?.currentItem, enabled != audioOnly else { return }
    TouchFeedback.light()
    audioOnly = enabled
    apply()
  }
}
struct PlaybackTrackSwitch: View {
  let player: any PlaybackEngine
  @State private var audioOnly = false
  var body: some View {
    if let native = player.nativePlayer { AVPlaybackTrackSwitch(player: native) }
    else if let mpv = player as? MPVPlayer {
      Toggle("仅播放音频", isOn: Binding(get: { audioOnly }, set: {
        TouchFeedback.light()
        audioOnly = $0
        mpv.audioOnly = $0
      })).onAppear { audioOnly = mpv.audioOnly }
    }
  }
}
private struct AVPlaybackTrackSwitch: View {
  @ObservedObject private var state: PlaybackTrackSwitchState
  init(player: AVPlayer) { state = .shared(player) }
  var body: some View {
    if state.available {
      Toggle("仅播放音频", isOn: Binding(get: { state.audioOnly }, set: { state.set($0) }))
    }
  }
}
