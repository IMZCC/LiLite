import ImageIO
import SwiftUI

struct GalleryZoom: UIViewRepresentable {
  let file: URL
  var paging: GalleryPagingEdges? = nil, active = true
  /// 0 = let the system pick the frame rate.
  private let fps = 0
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
    var url: URL?, source: CGImageSource?, link: CADisplayLink?, frame = 0, next = 0.0,
      lastSize = CGSize.zero
    private var pixel = CGSize.zero
    private var requested = 0
    func rate(_ value: Int) {
      requested = value
      guard let link else { return }
      let cap = scroll?.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
      let target = Float(min(max(1, cap), max(1, value)))
      link.preferredFrameRateRange =
        value > 0
        ? CAFrameRateRange(minimum: min(24, target), maximum: target, preferred: target) : .default
    }
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
    func load(_ file: URL) {
      guard url != file else { return }
      stop()
      url = file
      guard let src = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(src) > 0
      else { return }
      source = src
      frame = 0
      next = 0
      lastSize = .zero
      if let image = decoded(src, 0) {
        scroll?.canvas.image = image
        pixel = image.size
        layout()
      }
      if CGImageSourceGetCount(src) > 1 {
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        rate(requested)
      }
    }
    private func decoded(_ s: CGImageSource, _ i: Int) -> UIImage? {
      let count = CGImageSourceGetCount(s)
      let opts =
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: count == 1 ? 8192 : 1600,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
      return CGImageSourceCreateThumbnailAtIndex(s, i, opts).map { UIImage(cgImage: $0) }
    }
    private func delay(_ s: CGImageSource, _ i: Int) -> Double {
      let p = (CGImageSourceCopyPropertiesAtIndex(s, i, nil) as? [String: Any]) ?? [:]
      for v in p.values {
        if let o = v as? [String: Any],
          let d = (o["UnclampedDelayTime"] ?? o["DelayTime"]) as? NSNumber
        {
          return d.doubleValue < 0.011 ? 0.1 : min(60, d.doubleValue)
        }
      }
      return 0.1
    }
    @objc func tick(_ l: CADisplayLink) {
      guard let s = source else { return }
      if next == 0 {
        next = l.timestamp + delay(s, frame)
        return
      }
      guard l.timestamp >= next else { return }
      frame = (frame + 1) % CGImageSourceGetCount(s)
      if let image = decoded(s, frame) { scroll?.canvas.image = image }
      next = l.timestamp + delay(s, frame)
    }
    func stop() {
      link?.invalidate()
      link = nil
      source = nil
      url = nil
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
    return s
  }
  func updateUIView(_ view: ImageScroll, context: Context) {
    if active { paging?.scroll = view } else if paging?.scroll === view { paging?.scroll = nil }
    context.coordinator.load(file)
    context.coordinator.rate(fps)
  }
  static func dismantleUIView(_ view: ImageScroll, coordinator: Coordinator) {
    view.resized = nil
    coordinator.stop()
  }
}
