import AVFoundation
import Combine
import SwiftUI

enum PlaybackEngineKind: String, CaseIterable {
  case mpv
  case avplayer
  static let key = "player.engine"
  static var selected: Self { Self(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .mpv }
  var title: String { self == .mpv ? "mpv" : "AVPlayer" }
}

/// Shared transport and clock contract. System-only surfaces unwrap AVPlayer at their boundary.
@MainActor protocol PlaybackEngine: AnyObject {
  var engineKind: PlaybackEngineKind { get }
  var playbackItem: AnyObject? { get }
  var playbackDuration: Double { get }
  var playbackSize: CGSize { get }
  var playbackReady: Bool { get }
  var playbackBuffers: [ClosedRange<Double>] { get }
  var itemPublisher: AnyPublisher<AnyObject?, Never> { get }
  var statePublisher: AnyPublisher<Void, Never> { get }
  var rate: Float { get set }
  var defaultRate: Float { get set }
  var presentationVolume: Float { get set }
  var isMuted: Bool { get set }
  var isExternalPlaybackActive: Bool { get }
  var timeControlStatus: AVPlayer.TimeControlStatus { get }
  func currentTime() -> CMTime
  func play()
  func pause()
  func playImmediately(atRate rate: Float)
  func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime, completionHandler: @escaping (Bool) -> Void)
  func addPeriodicTimeObserver(forInterval interval: CMTime, queue: DispatchQueue?, using block: @escaping (CMTime) -> Void) -> Any
  func removeTimeObserver(_ observer: Any)
}

extension PlaybackEngine {
  var supportsSystemVideo: Bool { engineKind == .avplayer }
  var nativePlayer: AVPlayer? { self as? AVPlayer }
  func seek(to time: CMTime) {
    seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
  }
  func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) {
    seek(to: time, toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter) { _ in }
  }
  func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) async -> Bool {
    await withCheckedContinuation { continuation in
      seek(to: time, toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter) {
        continuation.resume(returning: $0)
      }
    }
  }
}

extension AVPlayer: PlaybackEngine {
  var engineKind: PlaybackEngineKind { .avplayer }
  var playbackItem: AnyObject? { currentItem }
  var playbackDuration: Double { currentItem?.duration.seconds ?? 0 }
  var playbackSize: CGSize { currentItem?.presentationSize ?? .zero }
  var playbackReady: Bool { currentItem?.status == .readyToPlay }
  var playbackBuffers: [ClosedRange<Double>] {
    (currentItem?.loadedTimeRanges ?? []).compactMap {
      let range = $0.timeRangeValue
      let start = range.start.seconds
      let end = range.end.seconds
      return start.isFinite && end.isFinite && end > max(0, start) ? max(0, start)...end : nil
    }
  }
  var itemPublisher: AnyPublisher<AnyObject?, Never> {
    publisher(for: \.currentItem).map { $0 as AnyObject? }.eraseToAnyPublisher()
  }
  var statePublisher: AnyPublisher<Void, Never> {
    Publishers.MergeMany([
      publisher(for: \.rate).map { _ in () }.eraseToAnyPublisher(),
      publisher(for: \.defaultRate).map { _ in () }.eraseToAnyPublisher(),
      publisher(for: \.timeControlStatus).map { _ in () }.eraseToAnyPublisher(),
      publisher(for: \.isExternalPlaybackActive).map { _ in () }.eraseToAnyPublisher(),
    ]).eraseToAnyPublisher()
  }
}

struct PlaybackEnginePicker: View {
  @AppStorage(PlaybackEngineKind.key) private var selected = PlaybackEngineKind.mpv.rawValue
  var body: some View {
    Picker("播放器内核", selection: $selected) {
      ForEach(PlaybackEngineKind.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
    }
  }
}

struct PlaybackEngineSettings: View {
  var body: some View {
    Form {
      Section {
        PlaybackEnginePicker()
      } footer: {
        Text("mpv：与原版同款内核，支持更多解码与倍速选项\n两种内核均支持画中画与投屏，AVPlayer 另支持隔空播放\n重新进入视频后生效")
      }
    }.navigationTitle("播放器内核")
  }
}
