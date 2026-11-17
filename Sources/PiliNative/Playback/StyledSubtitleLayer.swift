import AVFoundation
import CLiveRemux
import SwiftUI

private struct StyledSubtitleKey: EnvironmentKey { static let defaultValue: SubtitleSession? = nil }
extension EnvironmentValues {
  var styledSubtitles: SubtitleSession? {
    get { self[StyledSubtitleKey.self] }
    set { self[StyledSubtitleKey.self] = newValue }
  }
}

private final class ASSWork: @unchecked Sendable {
  // All libass calls run on a private serial queue. Output Data owns its pixels after return.
  private var renderer: OpaquePointer?
  struct Tile: Sendable { let box: CGRect, bytes: Data }
  enum Frame: Sendable {
    case same, clear
    case image(Tile)
  }
  init(_ bytes: Data) {
    renderer = bytes.withUnsafeBytes {
      pili_ass_open($0.bindMemory(to: UInt8.self).baseAddress, $0.count, nil)
    }
  }
  deinit { pili_ass_free(renderer) }
  var valid: Bool { pili_ass_events(renderer) > 0 }
  func render(w: Int, h: Int, sw: Int, sh: Int, ms: Int64) -> Frame {
    var f = PiliASSFrame()
    let state = pili_ass_render(renderer, Int32(w), Int32(h), Int32(sw), Int32(sh), ms, &f)
    if state == 0 { return .same }
    guard state > 0, let ptr = f.pixels, f.width > 0, f.height > 0 else { return .clear }
    return .image(
      .init(
        box: CGRect(x: Int(f.x), y: Int(f.y), width: Int(f.width), height: Int(f.height)),
        bytes: Data(bytes: ptr, count: Int(f.stride) * Int(f.height))))
  }
}
enum ASSImportCheck { static func valid(_ data: Data) -> Bool { ASSWork(data).valid } }

private struct ScriptPlane: UIViewRepresentable {
  let script: SubtitleSession.Script
  let player: any PlaybackEngine
  let gravity: String
  func makeUIView(context: Context) -> Surface { Surface() }
  func updateUIView(_ view: Surface, context: Context) {
    view.configure(script, player: player, gravity: gravity)
  }
  static func dismantleUIView(_ uiView: Surface, coordinator: ()) { uiView.close() }
  final class Surface: UIView {
    private let work = DispatchQueue(label: "PiliNative.ass.render", qos: .userInitiated)
    // Renderer lives on work; display link and presentation state on main.
    private nonisolated(unsafe) var engine: ASSWork?
    private weak var player: (any PlaybackEngine)?
    private var doc: SubtitleSession.Script?, scriptID = "", gravity = "fit", epoch = UUID(),
      pending = false
    private var display: CADisplayLink?, last: Request?
    private let imageLayer = CALayer()
    private struct Request: Equatable {
      let w: Int, h: Int, sw: Int, sh: Int, ms: Int64, rect: CGRect
    }
    override init(frame: CGRect) {
      super.init(frame: frame)
      isOpaque = false
      isUserInteractionEnabled = false
      layer.masksToBounds = true
      layer.addSublayer(imageLayer)
      NotificationCenter.default.addObserver(
        self, selector: #selector(purge), name: UIApplication.didReceiveMemoryWarningNotification,
        object: nil)
    }
    @objc private func purge() {
      epoch = UUID()
      pending = false
      last = nil
      scriptID = ""
      imageLayer.contents = nil
      work.async { [weak self] in self?.engine = nil }
    }
    required init?(coder: NSCoder) { nil }
    func configure(_ doc: SubtitleSession.Script, player: any PlaybackEngine, gravity: String) {
      let changed = self.player !== player || self.gravity != gravity || scriptID != doc.id
      self.player = player
      self.gravity = gravity
      self.doc = doc
      if scriptID != doc.id {
        epoch = UUID()
        scriptID = doc.id
        pending = false
        last = nil
        imageLayer.contents = nil
        work.async { [weak self] in self?.engine = ASSWork(doc.data) }
      }
      if changed { tick() }
    }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      display?.invalidate()
      display = nil
      if window != nil {
        let d = CADisplayLink(target: self, selector: #selector(tick))
        d.preferredFrameRateRange = .init(minimum: 10, maximum: 30, preferred: 30)
        d.add(to: .main, forMode: .common)
        display = d
      }
    }
    override func layoutSubviews() {
      super.layoutSubviews()
      tick()
    }
    @objc private func tick() {
      guard !pending, let p = player, let item = p.playbackItem, window != nil, bounds.width > 0,
        bounds.height > 0
      else { return }
      imageLayer.isHidden = p.isExternalPlaybackActive
      guard !imageLayer.isHidden else { return }
      if scriptID.isEmpty, let doc {
        configure(doc, player: p, gravity: gravity)
        return
      }
      let t = p.currentTime().seconds
      guard t.isFinite, t >= 0, t <= 31_536_000 else { return }
      let src = p.playbackSize
      let valid =
        src.width.isFinite && src.height.isFinite && src.width > 0 && src.height > 0
        && src.width <= 32768 && src.height <= 32768
      var rect = bounds
      if valid, gravity == "fit" || gravity == "fill" {
        let x = bounds.width / src.width
        let y = bounds.height / src.height
        let k = gravity == "fit" ? min(x, y) : max(x, y)
        let size = CGSize(width: src.width * k, height: src.height * k)
        rect = .init(
          x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width,
          height: size.height)
      }
      guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else {
        return
      }
      let scale = min(
        window?.screen.scale ?? 1, 1920 / max(rect.width, rect.height),
        sqrt(2_300_000 / (rect.width * rect.height)))
      let w = max(1, Int(rect.width * scale))
      let h = max(1, Int(rect.height * scale))
      let sw = valid ? Int(src.width) : w
      let sh = valid ? Int(src.height) : h
      let r = Request(w: w, h: h, sw: sw, sh: sh, ms: Int64(t * 1000), rect: rect)
      guard r != last else { return }
      let key = epoch
      let prior = last
      last = r
      pending = true
      work.async { [weak self] in
        guard let self else { return }
        let result = self.engine?.render(w: r.w, h: r.h, sw: r.sw, sh: r.sh, ms: r.ms) ?? .clear
        DispatchQueue.main.async { [weak self] in
          guard let self, self.epoch == key else { return }
          self.pending = false
          if case .same = result {
            if let prior, prior.rect != r.rect, prior.rect.width > 0, prior.rect.height > 0 {
              let frame = self.imageLayer.frame
              let rx = r.rect.width / prior.rect.width
              let ry = r.rect.height / prior.rect.height
              CATransaction.begin()
              CATransaction.setDisableActions(true)
              self.imageLayer.frame = CGRect(
                x: r.rect.minX + (frame.minX - prior.rect.minX) * rx,
                y: r.rect.minY + (frame.minY - prior.rect.minY) * ry, width: frame.width * rx,
                height: frame.height * ry)
              CATransaction.commit()
            }
            return
          }
          CATransaction.begin()
          CATransaction.setDisableActions(true)
          defer { CATransaction.commit() }
          guard case .image(let image) = result,
            let provider = CGDataProvider(data: image.bytes as CFData),
            let picture = CGImage(
              width: Int(image.box.width), height: Int(image.box.height), bitsPerComponent: 8,
              bitsPerPixel: 32, bytesPerRow: Int(image.box.width) * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
              provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
          else {
            self.imageLayer.contents = nil
            return
          }
          let x = r.rect.width / CGFloat(r.w)
          let y = r.rect.height / CGFloat(r.h)
          self.imageLayer.frame = CGRect(
            x: r.rect.minX + image.box.minX * x, y: r.rect.minY + image.box.minY * y,
            width: image.box.width * x, height: image.box.height * y)
          self.imageLayer.contents = picture
        }
      }
    }
    func close() {
      epoch = UUID()
      display?.invalidate()
      display = nil
      imageLayer.contents = nil
      doc = nil
      player = nil
      NotificationCenter.default.removeObserver(self)
      work.async { [weak self] in self?.engine = nil }
    }
  }
}
struct StyledSubtitleLayer: View {
  @ObservedObject var session: SubtitleSession
  let player: any PlaybackEngine
  let gravity: String
  var body: some View {
    ZStack {
      ForEach(session.scripts) { script in
        ScriptPlane(script: script, player: player, gravity: gravity)
      }
    }.allowsHitTesting(false).accessibilityHidden(true)
  }
}
