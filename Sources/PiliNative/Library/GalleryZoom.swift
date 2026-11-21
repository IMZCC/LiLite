import ImageIO
import SwiftUI

struct GalleryZoom: UIViewRepresentable {
  let file: URL
  var paging: GalleryPagingEdges? = nil, active = true
  /// A single tap (not the first of a double tap): the full-screen viewer closes on it.
  var tapped: (() -> Void)? = nil
  final class ImageScroll: UIScrollView {
    let canvas = UIImageView()
    var resized: (() -> Void)?
    override func layoutSubviews() {
      super.layoutSubviews()
      resized?()
    }
  }
  final class Coordinator: NSObject, UIScrollViewDelegate {
    weak var scroll: ImageScroll?
    var tapped: (() -> Void)?
    @objc func singleTap(_ tap: UITapGestureRecognizer) { tapped?() }
    private var file: URL?
    private var frames: GalleryFrames?
    private var firstLoad: Task<Void, Never>?
    private var animation: Task<Void, Never>?
    private var active = false
    private var frame = 0
    private var count = 0
    private var delay = 0.1
    private var lastSize = CGSize.zero
    private var pixel = CGSize.zero

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { scroll?.canvas }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }
    func center() {
      guard let s = scroll else { return }
      let dx = max(0, (s.bounds.width - s.contentSize.width) / 2)
      let dy = max(0, (s.bounds.height - s.contentSize.height) / 2)
      let inset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
      if s.contentInset != inset { s.contentInset = inset }
    }
    func layout() {
      guard let s = scroll, s.bounds.size != lastSize, s.bounds.width > 0, s.bounds.height > 0,
        pixel.width > 0, pixel.height > 0
      else { return }
      lastSize = s.bounds.size
      let sx = s.bounds.width / pixel.width
      let sy = s.bounds.height / pixel.height
      let z = pixel.height > pixel.width * 3 ? sx : min(sx, sy)
      s.minimumZoomScale = min(z, 1)
      s.maximumZoomScale = max(z * 5, 2)
      s.zoomScale = 1
      s.canvas.frame = CGRect(origin: .zero, size: pixel)
      s.contentSize = pixel
      s.minimumZoomScale = z
      s.zoomScale = z
      center()
    }
    @objc func doubleTap(_ tap: UITapGestureRecognizer) {
      guard let s = scroll else { return }
      if s.zoomScale > s.minimumZoomScale * 1.05 {
        s.setZoomScale(s.minimumZoomScale, animated: true)
        return
      }
      let target = min(s.maximumZoomScale, s.minimumZoomScale * 2.5)
      let loc = tap.location(in: s.canvas)
      let w = s.bounds.width / target
      let h = s.bounds.height / target
      s.zoom(to: CGRect(x: loc.x - w / 2, y: loc.y - h / 2, width: w, height: h), animated: true)
    }
    func load(_ file: URL, active: Bool) {
      if self.file == file {
        guard self.active != active else { return }
        self.active = active
        updateAnimation()
        return
      }
      stop()
      self.file = file
      self.active = active
      let frames = GalleryFrames(file: file)
      self.frames = frames
      firstLoad = Task { [weak self] in
        guard let first = await frames.read(0), !Task.isCancelled, let self else { return }
        count = first.count
        delay = first.delay
        if let image = first.image {
          let still = UIImage(cgImage: image)
          scroll?.canvas.image = still
          pixel = still.size
          layout()
        }
        updateAnimation()
      }
    }

    private func updateAnimation() {
      animation?.cancel()
      animation = nil
      guard active, count > 1, let frames else { return }
      animation = Task { [weak self] in
        while !Task.isCancelled {
          guard let self else { return }
          let deadline = ContinuousClock.now + .seconds(delay)
          let next = (frame + 1) % count
          guard let decoded = await frames.read(next), !Task.isCancelled else { return }
          do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
          guard !Task.isCancelled else { return }
          if let image = decoded.image { scroll?.canvas.image = UIImage(cgImage: image) }
          frame = next
          delay = decoded.delay
        }
      }
    }

    func stop() {
      firstLoad?.cancel()
      animation?.cancel()
      firstLoad = nil
      animation = nil
      file = nil
      frames = nil
      count = 0
      frame = 0
      pixel = .zero
      lastSize = .zero
      scroll?.canvas.image = nil
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeUIView(context: Context) -> ImageScroll {
    let s = ImageScroll()
    let c = context.coordinator
    c.scroll = s
    s.delegate = c
    s.contentInsetAdjustmentBehavior = .never
    s.canvas.contentMode = .scaleAspectFit
    s.addSubview(s.canvas)
    s.resized = { [weak c] in c?.layout() }
    let g = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubleTap(_:)))
    g.numberOfTapsRequired = 2
    s.addGestureRecognizer(g)
    let single = UITapGestureRecognizer(target: c, action: #selector(Coordinator.singleTap(_:)))
    single.require(toFail: g)
    s.addGestureRecognizer(single)
    return s
  }
  func updateUIView(_ view: ImageScroll, context: Context) {
    context.coordinator.tapped = tapped
    if active { paging?.scroll = view } else if paging?.scroll === view { paging?.scroll = nil }
    context.coordinator.load(file, active: active)
  }
  static func dismantleUIView(_ view: ImageScroll, coordinator: Coordinator) {
    view.resized = nil
    coordinator.stop()
  }
}

/// One reader per file. ImageIO access is serialized, including when a swipe cancels a decode.
private actor GalleryFrames {
  struct Frame {
    let image: CGImage?
    let count: Int
    let delay: Double
  }

  let file: URL
  private lazy var source = CGImageSourceCreateWithURL(file as CFURL, nil)
  init(file: URL) { self.file = file }

  func read(_ index: Int) -> Frame? {
    guard !Task.isCancelled, let source else { return nil }
    let count = CGImageSourceGetCount(source)
    guard index < count else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: count == 1 ? 8192 : 1600,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    var delay = 0.1
    if count > 1, let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] {
      for case let values as [String: Any] in properties.values {
        if let seconds = (values["UnclampedDelayTime"] ?? values["DelayTime"]) as? NSNumber {
          let value = seconds.doubleValue
          if value.isFinite, value >= 0.011 { delay = min(60, value) }
          break
        }
      }
    }
    return Frame(image: image, count: count, delay: delay)
  }
}
