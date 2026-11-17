import AVFoundation
import CLiveRemux
import MediaToolbox
import ObjectiveC

@MainActor final class ItemAudioGain {
  static let key = "audio.gainPercent"
  static var percent: Int32 {
    let n = UserDefaults.standard.object(forKey: key) as? Double ?? 100
    return Int32(n.isFinite ? min(300, max(100, n.rounded())) : 100)
  }
  private static var association: UInt8 = 0
  static func attach(_ item: AVPlayerItem) {
    // HLS audio is processed by its rendition rather than AVAudioMix.
    if let a = item.asset as? AVURLAsset,
       a.url.pathExtension.lowercased() == "m3u8" ||
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(a.url.host?.lowercased() ?? "") { return }
    if let active = objc_getAssociatedObject(item, &association) as? ItemAudioGain {
      active.update(); return
    }
    let gain = ItemAudioGain(item)
    objc_setAssociatedObject(item, &association, gain, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    gain.update()
  }
  private weak var item: AVPlayerItem?
  private var taps = [MTAudioProcessingTap]()
  private var task: Task<Void, Never>?
  private var notice: NSObjectProtocol?
  private var attempted = false
  private init(_ item: AVPlayerItem) {
    self.item = item
    notice = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor [weak self] in self?.update() }
    }
  }
  private func update() {
    let p = Self.percent
    if !taps.isEmpty { for t in taps { pl_gain_set_percent(t, p) }; return }
    guard p > 100, !attempted, task == nil, let asset = item?.asset else { return }
    task = Task { [weak self] in
      let protected = try? await asset.load(.hasProtectedContent)
      guard !Task.isCancelled, protected == false else { self?.task = nil; return }
      let tracks = try? await asset.loadTracks(withMediaType: .audio)
      guard !Task.isCancelled, let self, let item = self.item else { return }
      self.task = nil
      guard let tracks, !tracks.isEmpty, Self.percent > 100 else { return }
      self.attempted = true
      let mix = AVMutableAudioMix()
      var params = item.audioMix?.inputParameters ?? []
      for track in tracks {
        let i = params.firstIndex { $0.trackID == track.trackID }
        if let i, params[i].audioTapProcessor != nil { continue }
        let param: AVMutableAudioMixInputParameters
        if let i {
          guard let copy = params[i].mutableCopy() as? AVMutableAudioMixInputParameters else { continue }
          param = copy
        } else { param = AVMutableAudioMixInputParameters(track: track) }
        guard let tap = pl_gain_create_tap(Self.percent) else { continue }
        param.audioTapProcessor = tap
        self.taps.append(tap)
        if let i { params[i] = param } else { params.append(param) }
      }
      if !self.taps.isEmpty { mix.inputParameters = params; item.audioMix = mix }
    }
  }
  deinit {
    task?.cancel()
    if let notice { NotificationCenter.default.removeObserver(notice) }
  }
}
