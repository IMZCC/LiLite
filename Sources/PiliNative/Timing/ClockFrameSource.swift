import AVFoundation

/// One in-flight extraction and one pending frame. A slow decoder never queues display-link work.
final class ClockFrameSource: @unchecked Sendable {
  struct Frame {
    let image: CVPixelBuffer
    let pts: CMTime
  }
  private let output: AVPlayerItemVideoOutput
  private let queue = DispatchQueue(label: "pili.clock.picture", qos: .userInitiated)
  private let lock = NSLock()
  private var generation = 0, busy = false
  private var pending: Frame?

  init(_ output: AVPlayerItemVideoOutput) { self.output = output }

  func reset() {
    lock.withLock { generation += 1; pending = nil }
  }

  func take() -> Frame? {
    lock.withLock { defer { pending = nil }; return pending }
  }

  func request(_ time: CMTime) {
    let ticket: Int? = lock.withLock {
      guard !busy else { return nil }
      busy = true
      return generation
    }
    guard let ticket else { return }
    queue.async { [self] in
      let frame: Frame? = autoreleasepool {
        guard output.hasNewPixelBuffer(forItemTime: time) else { return nil }
        var pts = CMTime.invalid
        guard let image = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &pts),
          pts.isNumeric else { return nil }
        return Frame(image: image, pts: pts)
      }
      lock.withLock {
        busy = false
        if generation == ticket, let frame { pending = frame }
      }
    }
  }
}
