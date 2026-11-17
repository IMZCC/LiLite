import AVFoundation
import SwiftUI

@MainActor final class VideoScenePause: NSObject {
  func userIntent(_ engine: (any PlaybackEngine)?) {
    if let player = engine as? AVPlayer { userIntent(player as AVPlayer?) }
    else { (engine as? MPVPlayer)?.cancelInterruption() }
  }
  static let shared = VideoScenePause()
  private final class Registration {
    weak var player: AVPlayer?, scene: UIWindowScene?, item: AVPlayerItem?
    var memory = SceneResumeMemory<ObjectIdentifier>()
    var apply: Task<Void, Never>?
    func reset() {
      apply?.cancel()
      apply = nil
      item = nil
      memory = .init()
    }
  }
  private let records = NSMapTable<UIView, Registration>.weakToStrongObjects()
  private var sessionEvents: PlaybackSessionEvents?
  private var audioUnavailable = false
  func didPlay() { audioUnavailable = false }
  func resetAll() { all.forEach { $0.reset() } }
  override private init() {
    super.init()
    let c = NotificationCenter.default
    c.addObserver(
      self, selector: #selector(inactive(_:)), name: UIScene.willDeactivateNotification, object: nil
    )
    c.addObserver(
      self, selector: #selector(background(_:)), name: UIScene.didEnterBackgroundNotification,
      object: nil)
    c.addObserver(
      self, selector: #selector(active(_:)), name: UIScene.didActivateNotification, object: nil)
    sessionEvents = PlaybackSessionEvents { [weak self] event in
      switch event {
      case .systemInterruption, .appInactive, .outputLost:
        self?.audioUnavailable = true
        self?.all.forEach { $0.reset() }
      case .recommendation:
        self?.all.forEach { $0.reset() }
      }
    }
  }
  func bind(_ marker: UIView, player: AVPlayer?) {
    guard let player, let scene = marker.window?.windowScene else {
      records.object(forKey: marker)?.reset()
      records.removeObject(forKey: marker)
      return
    }
    if let old = records.object(forKey: marker), old.player === player && old.scene === scene {
      return
    }
    records.object(forKey: marker)?.reset()
    let r = Registration()
    r.player = player
    r.scene = scene
    records.setObject(r, forKey: marker)
  }
  private var all: [Registration] {
    records.objectEnumerator()?.allObjects as? [Registration] ?? []
  }
  private var enabled: Bool {
    UserDefaults.standard.bool(forKey: InterfaceInteraction.pauseWhenBackground)
  }
  func userIntent(_ player: AVPlayer?) {
    guard let player else { return }
    VideoInterruptionRecovery.shared.cancelPending(player)
    all.filter { $0.player === player }.forEach { $0.reset() }
  }
  private func snapshot(_ r: Registration) {
    guard !audioUnavailable, enabled, let p = r.player, let item = p.currentItem,
      !VideoTransport.continuesInBackground(p),
      p.rate > 0 || p.timeControlStatus == .waitingToPlayAtSpecifiedRate
    else { return }
    r.item = item
    r.memory.capture(
      item: ObjectIdentifier(item), rate: p.rate > 0 ? p.rate : max(0.1, p.defaultRate),
      wanted: true)
  }
  @objc private func inactive(_ n: Notification) {
    guard let scene = n.object as? UIWindowScene else { return }
    for r in all where r.scene === scene {
      r.reset()
      snapshot(r)
    }
  }
  @objc private func background(_ n: Notification) {
    guard let scene = n.object as? UIWindowScene else { return }
    for r in all where r.scene === scene {
      if r.item == nil { snapshot(r) }
      guard let p = r.player, let item = r.item, p.currentItem === item,
        r.memory.enter(
          current: ObjectIdentifier(item),
          eligible: enabled && !VideoTransport.continuesInBackground(p))
      else {
        r.reset()
        continue
      }
      // AVKit may announce an automatic PiP handoff just after the scene notification.
      r.apply = Task { [weak r] in
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, let r, r.memory.background, let player = r.player,
          r.scene?.activationState == .background, player.currentItem === r.item,
          !VideoTransport.continuesInBackground(player)
        else { return }
        player.pause()
      }
    }
  }
  @objc private func active(_ n: Notification) {
    PlaybackSleepTimer.shared.check()
    guard let scene = n.object as? UIWindowScene else { return }
    for r in all where r.scene === scene {
      if let p = r.player, let item = r.item, p.currentItem === item, item.status == .readyToPlay,
        let rate = r.memory.restore(
          current: ObjectIdentifier(item),
          eligible: enabled && !VideoTransport.continuesInBackground(p)
            && !ListenQueue.shared.playing && !ListenQueue.shared.loading, paused: p.rate == 0)
      {
        p.playImmediately(atRate: rate)
      }
      r.reset()
    }
  }
  func pipStarted(_ p: AVPlayer) {
    for r in all where r.player === p {
      if let item = r.item, p.currentItem === item, item.status == .readyToPlay,
        let rate = r.memory.restore(
          current: ObjectIdentifier(item),
          eligible: !ListenQueue.shared.playing && !ListenQueue.shared.loading, paused: p.rate == 0)
      {
        p.playImmediately(atRate: rate)
      }
      r.reset()
    }
  }

}
struct VideoSceneMarker: UIViewRepresentable {
  let player: AVPlayer
  final class Marker: UIView {
    weak var player: AVPlayer?
    override func didMoveToWindow() {
      super.didMoveToWindow()
      VideoScenePause.shared.bind(self, player: player)
    }
  }
  func makeUIView(context: Context) -> Marker {
    let m = Marker()
    m.isUserInteractionEnabled = false
    return m
  }
  func updateUIView(_ v: Marker, context: Context) {
    v.player = player
    VideoScenePause.shared.bind(v, player: player)
  }
  static func dismantleUIView(_ m: Marker, coordinator: ()) {
    VideoScenePause.shared.bind(m, player: nil)
  }
}
