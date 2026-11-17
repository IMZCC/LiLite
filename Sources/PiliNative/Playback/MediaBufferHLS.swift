import AVFoundation

/// Native HLS owns its packet buffers; use the selected stream's advertised or measured media rate
/// to express the live byte budget as an AVPlayer forward-duration hint.
@MainActor final class MediaBufferHLS {
  private weak var item: AVPlayerItem?
  private let timeLimit: Double
  private var bytes: Int
  private var watch: Task<Void, Never>?
  private var pressure: MediaBufferPressure?
  init(item: AVPlayerItem) {
    self.item = item
    timeLimit = item.preferredForwardBufferDuration
    bytes = max(64 * 1024, MediaBufferPolicy.current(live: true))
    pressure = MediaBufferPressure { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.bytes = min(self.bytes, 256 * 1024)
        self.update()
      }
    }
    watch = Task { [weak self] in
      while !Task.isCancelled {
        guard self?.item != nil else { return }
        self?.update()
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
      }
    }
  }
  private func update() {
    guard let item, let log = item.accessLog()?.events.last else { return }
    var rate = log.indicatedBitrate
    if !(rate.isFinite && rate > 0), log.segmentsDownloadedDuration.isFinite,
      log.segmentsDownloadedDuration > 0, log.numberOfBytesTransferred > 0
    {
      rate = Double(log.numberOfBytesTransferred) * 8 / log.segmentsDownloadedDuration
    }
    guard
      let seconds = MediaBufferPolicy.liveSeconds(
        capacity: bytes, bitsPerSecond: rate, limit: timeLimit)
    else { return }
    let target = min(3600, seconds)
    if abs(item.preferredForwardBufferDuration - target) > min(0.15, target / 10) {
      item.preferredForwardBufferDuration = target
    }
  }
  func stop() {
    watch?.cancel()
    watch = nil
    item = nil
    pressure = nil
  }
  deinit { watch?.cancel() }
}
