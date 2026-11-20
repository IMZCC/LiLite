import AVFoundation
import Foundation

@MainActor enum VideoTransport {
  static func background(_ engine: any PlaybackEngine, temporary: Bool?) {
    if let player = engine as? AVPlayer { background(player, temporary: temporary) }
    else if let mpv = engine as? MPVPlayer { mpv.backgroundOverride = temporary }
  }
  static func quietPiP(_ engine: any PlaybackEngine) -> Bool {
    guard let player = engine as? AVPlayer else {
      return PictureSession.shared(engine).inPictureInPicture && UserDefaults.standard.bool(forKey: quietPiPKey)
    }
    return quietPiP(player)
  }
  static func continuesInBackground(_ engine: any PlaybackEngine) -> Bool {
    if let player = engine as? AVPlayer { return continuesInBackground(player) }
    return (engine as? MPVPlayer)?.continuesInBackground ?? false
  }
  static let autoKey = "play.onEntry", backgroundKey = "play.background",
    bufferKey = "play.bufferSeconds", liveBufferKey = "live.bufferSeconds"
  /// Off by default, like the original's autoPlayEnable: the detail page waits for a tap.
  /// On unless turned off, as the official client starts a video as soon as its page opens.
  static var playsOnEntry: Bool { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
  private static let temporaryBackground = NSMapTable<AVPlayer, NSNumber>.weakToStrongObjects()
  static func background(_ player: AVPlayer, temporary: Bool?) {
    if let temporary {
      temporaryBackground.setObject(NSNumber(value: temporary), forKey: player)
    } else {
      temporaryBackground.removeObject(forKey: player)
    }
    background(player)
  }
  static let pipChanged = Notification.Name("pili.video.pipChanged")
  static let quietPiPKey = "dm.quietPiP"
  static func quietPiP(_ player: AVPlayer) -> Bool {
    pipPlayers.contains(player) && UserDefaults.standard.bool(forKey: quietPiPKey)
  }
  private static let pipPlayers = NSHashTable<AVPlayer>.weakObjects()
  static func pip(_ player: AVPlayer?, _ active: Bool) {
    guard let player else { return }
    PictureSession.shared(player).setPictureInPicture(active)
    if active {
      pipPlayers.add(player)
      VideoScenePause.shared.pipStarted(player)
    } else {
      pipPlayers.remove(player)
    }
    background(player)
    NotificationCenter.default.post(name: pipChanged, object: player)
  }
  static func continuesInBackground(_ player: AVPlayer) -> Bool {
    pipPlayers.contains(player)
      || (temporaryBackground.object(forKey: player)?.boolValue
        ?? UserDefaults.standard.bool(forKey: backgroundKey))
  }
  static func background(_ player: AVPlayer) {
    let policy: AVPlayerAudiovisualBackgroundPlaybackPolicy =
      continuesInBackground(player) ? .continuesIfPossible : .pauses
    if player.audiovisualBackgroundPlaybackPolicy != policy {
      player.audiovisualBackgroundPlaybackPolicy = policy
    }
  }
  static func prepare(_ player: AVPlayer, _ item: AVPlayerItem, live: Bool = false) {
    VideoInterruptionRecovery.shared.register(player)
    background(player)
    ItemAudioGain.attach(item)
    let value =
      UserDefaults.standard.object(forKey: live ? liveBufferKey : bufferKey) as? Double
      ?? (live ? 0 : 16)
    guard value.isFinite && (0...3600).contains(value) else { return }
    item.preferredForwardBufferDuration =
      live ? value : value * max(0.1, Double(player.defaultRate))
  }
}
