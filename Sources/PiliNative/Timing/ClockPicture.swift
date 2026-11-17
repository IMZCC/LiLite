import AVFoundation
import UIKit

@MainActor final class ClockPicture: UIView {
  private let screen = AVSampleBufferDisplayLayer()
  private var format: CMVideoFormatDescription?
  private var angle: CGAffineTransform = .identity
  var gravity: AVLayerVideoGravity = .resizeAspect { didSet { screen.videoGravity = gravity } }
  var moved: (() -> Void)?
  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.addSublayer(screen)
    isHidden = true
    isUserInteractionEnabled = false
  }
  required init?(coder: NSCoder) { nil }
  override func didMoveToWindow() {
    super.didMoveToWindow()
    moved?()
  }
  func transformPicture(_ t: CGAffineTransform) {
    angle = CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: 0, ty: 0)
    setNeedsLayout()
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    let turns = abs(angle.b) > abs(angle.a)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    screen.setAffineTransform(angle)
    screen.bounds = .init(
      origin: .zero, size: turns ? .init(width: bounds.height, height: bounds.width) : bounds.size)
    screen.position = .init(x: bounds.midX, y: bounds.midY)
    CATransaction.commit()
  }
  func clear() {
    isHidden = true
    screen.sampleBufferRenderer.flush(removingDisplayedImage: true)
    format = nil
  }
  func show(_ image: CVPixelBuffer, pts: CMTime) -> Bool {
    let renderer = screen.sampleBufferRenderer
    if renderer.status == .failed { renderer.flush(removingDisplayedImage: true) }
    guard renderer.isReadyForMoreMediaData else { return false }
    if format.map({ CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: image) }) != true {
      guard
        CMVideoFormatDescriptionCreateForImageBuffer(
          allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format)
          == noErr
      else { return false }
    }
    guard let format else { return false }
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: format,
        sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample,
      let list = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)
    else { return false }
    let dict = unsafeBitCast(CFArrayGetValueAtIndex(list, 0), to: CFMutableDictionary.self)
    CFDictionarySetValue(
      dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
      Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    renderer.enqueue(sample)
    return true
  }
}
