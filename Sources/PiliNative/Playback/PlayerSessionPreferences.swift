import Combine
import Foundation
import SwiftUI

/// The settings screen always edits defaults. Playback menus can instead keep choices for this player.
@MainActor final class PlayerSessionPreferences: ObservableObject {
  static let temporaryKey = "play.temporaryPreferences"
  let temporary: Bool
  private let defaults: UserDefaults
  private var values: [String: Int] = [:]
  private var observer: AnyCancellable?
  private struct Snapshot: Equatable {
    let bullets: Bool, liveBullets: Bool, background: Bool, controls: Bool, repeatMode: VideoRepeat
    let media: Data?
  }
  private var last: Snapshot?
  private var snapshot: Snapshot {
    Snapshot(bullets: bullets, liveBullets: liveBullets, background: background, controls: controls,
      repeatMode: repeatMode, media: defaults.data(forKey: NetworkMediaRules.key))
  }
  var changed: (() -> Void)?
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    temporary = defaults.bool(forKey: Self.temporaryKey)
    last = snapshot
    observer = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
      .receive(on: RunLoop.main).sink { [weak self] _ in
        guard let self else { return }
        let next = self.snapshot
        guard self.last != next else { return }
        self.last = next
        self.objectWillChange.send()
        self.changed?()
      }
  }
  private func put(_ key: String, _ n: Int, persist: (Int) -> Void) {
    objectWillChange.send()
    if temporary { values[key] = n } else { persist(n) }
    last = snapshot
    changed?()
  }
  private func flag(_ key: String, fallback: Bool) -> Bool {
    values[key].map { $0 != 0 } ?? defaults.object(forKey: key) as? Bool ?? fallback
  }
  private func setFlag(_ key: String, _ value: Bool) {
    put(key, value ? 1 : 0) { defaults.set($0 != 0, forKey: key) }
  }
  var bullets: Bool {
    get { flag("video.danmaku.enabled", fallback: true) }
    set { setFlag("video.danmaku.enabled", newValue) }
  }
  var liveBullets: Bool {
    get { flag("live.showChat", fallback: true) }
    set { setFlag("live.showChat", newValue) }
  }
  var background: Bool {
    get { flag(VideoTransport.backgroundKey, fallback: false) }
    set { setFlag(VideoTransport.backgroundKey, newValue) }
  }
  var controls: Bool {
    get { flag(SystemMediaControls.key, fallback: true) }
    set { setFlag(SystemMediaControls.key, newValue) }
  }
  var repeatMode: VideoRepeat {
    get {
      VideoRepeat(rawValue: values[VideoRepeat.key] ?? defaults.integer(forKey: VideoRepeat.key))
        ?? .pause
    }
    set { put(VideoRepeat.key, newValue.rawValue) { defaults.set($0, forKey: VideoRepeat.key) } }
  }
  func binding<T>(_ key: ReferenceWritableKeyPath<PlayerSessionPreferences, T>) -> Binding<T> {
    Binding(get: { self[keyPath: key] }, set: { self[keyPath: key] = $0 })
  }
  private func networkKey(_ audio: Bool) -> String {
    (MediaNetwork.shared.cellular ? "cell" : "wifi") + (audio ? ".audio" : ".video")
  }
  func overridden(audio: Bool) -> Int? { values[networkKey(audio)] }
  func record(_ id: Int, audio: Bool) {
    guard (audio ? NetworkMediaRules.audioIDs : NetworkMediaRules.videoIDs).contains(id) else {
      return
    }
    let cell = MediaNetwork.shared.cellular
    put(networkKey(audio), id) { _ in
      var r = NetworkMediaRules.current(defaults)
      if audio {
        if cell { r.cellAudio = id } else { r.wifiAudio = id }
      } else if cell {
        r.cellVideo = id
      } else {
        r.wifiVideo = id
      }
      try? r.save(defaults)
    }
  }
  func preferredQuality(_ available: [Int]) -> Int? {
    guard let q = overridden(audio: false) else {
      return PlaybackOption.preferredQuality(available)
    }
    return NetworkMediaRules.target(available, target: q, score: { $0 })
  }
}

struct SessionPlaybackSettings: View {
  @ObservedObject var session: PlayerSessionPreferences
  var body: some View {
    Menu {
      Toggle("后台继续播放", isOn: session.binding(\.background).withTouchFeedback)
      Toggle("系统播放控件", isOn: session.binding(\.controls))
    } label: {
      Label("后台与锁屏", systemImage: "play.square.stack")
    }
  }
}
