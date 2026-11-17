import AVFoundation
import CoreVideo

/// Own IOSurface leases, never a buffer that mpv will overwrite on its next frame.
/// All methods except control-timebase updates run on MPVRenderer's serial queue.
final class MPVPiPFrames: @unchecked Sendable {
  let layer: AVSampleBufferDisplayLayer
  let timebase: CMTimebase
  var sourceSize = CGSize.zero
  var renderSize = CGSize.zero
  var active = false
  var enabled = true
  var didEnqueue: (() -> Void)?
  private var pool: CVPixelBufferPool?
  private var poolSize = CGSize.zero
  private var format: CMVideoFormatDescription?
  private var lastFrame = -Double.infinity
  private var hasFrame = false
  init(layer: AVSampleBufferDisplayLayer, timebase: CMTimebase) {
    self.layer = layer
    self.timebase = timebase
  }
  func next(force: Bool) -> CVPixelBuffer? {
    guard enabled, force || active || ProcessInfo.processInfo.systemUptime - lastFrame >= 0.25 else { return nil }
    let size = MPVPiPPolicy.bufferSize(source: sourceSize, render: renderSize)
    guard size.width > 0, size.height > 0 else { return nil }
    if pool == nil || size != poolSize {
      pool = nil
      format = nil
      poolSize = size
      let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: Int(size.width),
        kCVPixelBufferHeightKey: Int(size.height),
        kCVPixelBufferIOSurfacePropertiesKey: [:],
        kCVPixelBufferOpenGLESCompatibilityKey: true,
        kCVPixelBufferMetalCompatibilityKey: true,
      ]
      CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
    }
    guard let pool else { return nil }
    var buffer: CVPixelBuffer?
    let limit = [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary
    guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, limit, &buffer) == kCVReturnSuccess else { return nil }
    return buffer
  }
  func enqueue(_ buffer: CVPixelBuffer) {
    if format == nil {
      CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
    }
    guard let format else { return }
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTimebaseGetTime(timebase), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
      formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
      let entry = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(entry, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    if #available(iOS 17.0, *) {
      let renderer = layer.sampleBufferRenderer
      if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
      guard renderer.isReadyForMoreMediaData else { return }
      renderer.enqueue(sample)
      guard renderer.status != .failed else { return }
    } else {
      if layer.status == .failed || layer.requiresFlushToResumeDecoding { layer.flush() }
      guard layer.isReadyForMoreMediaData else { return }
      layer.enqueue(sample)
      guard layer.status != .failed else { return }
    }
    lastFrame = ProcessInfo.processInfo.systemUptime
    if !hasFrame { hasFrame = true; didEnqueue?() }
  }
  func reset() {
    if #available(iOS 17.0, *) { layer.sampleBufferRenderer.flush(removingDisplayedImage: true) }
    else { layer.flushAndRemoveImage() }
    pool = nil
    format = nil
    hasFrame = false
    lastFrame = -.infinity
  }
}
