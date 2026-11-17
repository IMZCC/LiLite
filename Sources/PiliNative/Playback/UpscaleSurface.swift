import AVFoundation
import CoreVideo
import MetalKit
import SwiftUI

struct UpscaleLayer: View {
  let player: AVPlayer
  @ObservedObject var session: UpscaleSession
  let item: AVPlayerItem, gravity: String
  @Environment(\.scenePhase) private var phase
  var body: some View {
    if session.mode != .off && !session.nativeRange && phase == .active {
      UpscaleSurface(
        player: player, item: item, session: session, mode: session.mode, gravity: gravity
      )
      .id(session.activation).allowsHitTesting(false).accessibilityHidden(true)
    }
  }
}

private struct UpscaleSurface: UIViewRepresentable {
  let player: AVPlayer, item: AVPlayerItem, session: UpscaleSession, mode: UpscaleMode,
    gravity: String
  func makeCoordinator() -> Driver { Driver() }
  func makeUIView(context: Context) -> MTKView {
    let v = MTKView(frame: .zero)
    v.isPaused = true
    v.enableSetNeedsDisplay = false
    v.framebufferOnly = true
    v.colorPixelFormat = .bgra8Unorm
    v.isOpaque = false
    v.layer.opacity = 0
    v.clearColor = MTLClearColorMake(0, 0, 0, 1)
    v.isUserInteractionEnabled = false
    v.accessibilityElementsHidden = true
    context.coordinator.view = v
    return v
  }
  func updateUIView(_ v: MTKView, context: Context) {
    context.coordinator.update(
      player: player, item: item, session: session, mode: mode, gravity: gravity)
  }
  static func dismantleUIView(_ v: MTKView, coordinator: Driver) { coordinator.stop() }

  private final class FrameStorage: @unchecked Sendable {
    let pixel: CVPixelBuffer, metal: CVMetalTexture
    init(_ pixel: CVPixelBuffer, _ metal: CVMetalTexture) {
      self.pixel = pixel
      self.metal = metal
    }
  }
  @MainActor final class Driver: NSObject {
    weak var view: MTKView?
    private weak var player: AVPlayer?, item: AVPlayerItem?, state: UpscaleSession?
    private var output: AVPlayerItemVideoOutput?, gpu: UpscaleMetal?, queue: MTLCommandQueue?,
      cache: CVMetalTextureCache?
    private var mode = UpscaleMode.off, gravity = "fit", stamp = UUID(), active = false,
      busy = false
    private var shape: [Int] = [], targets: UpscaleTargets?, link: CADisplayLink?,
      task: Task<Void, Never>?
    private var lastFrame = 0.0, lastDisplay = CMTime.invalid, started = 0.0
    private var affine = CGAffineTransform.identity
    func update(
      player: AVPlayer, item: AVPlayerItem, session: UpscaleSession, mode: UpscaleMode,
      gravity: String
    ) {
      self.gravity = gravity
      guard self.item !== item || self.mode != mode else { return }
      stop()
      self.player = player
      self.item = item
      self.state = session
      self.mode = mode
      let gen = stamp
      task = Task {
        do {
          guard !(try await item.asset.load(.hasProtectedContent)) else { throw Signal.denied }
          let tracks = try await item.asset.loadTracks(withMediaType: .video)
          var transform = CGAffineTransform.identity
          for track in tracks {
            guard !(try await track.load(.mediaCharacteristics)).contains(.containsHDRVideo) else {
              throw Signal.hdr
            }
            for f in try await track.load(.formatDescriptions) {
              let ext = CMFormatDescriptionGetExtensions(f) as? [String: Any] ?? [:]
              guard !Self.wide(ext), !Self.dolby(CMFormatDescriptionGetMediaSubType(f)) else {
                throw Signal.hdr
              }
            }
          }
          if let t = tracks.first { transform = try await t.load(.preferredTransform) }
          let engine = try await UpscaleMetal.shared()
          try Task.checkCancellation()
          guard stamp == gen, player.currentItem === item, let v = view,
            let cmd = engine.device.makeCommandQueue()
          else { return }
          var textures: CVMetalTextureCache?
          guard
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, engine.device, nil, &textures)
              == kCVReturnSuccess, let textures
          else { throw Signal.failed }
          affine = transform
          gpu = engine
          queue = cmd
          cache = textures
          v.device = engine.device
          (v.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
          let tap = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
          ])
          tap.suppressesPlayerRendering = false
          item.add(tap)
          output = tap
          active = true
          started = CACurrentMediaTime()
          let timer = CADisplayLink(target: self, selector: #selector(frame))
          timer.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 60, preferred: 60)
          link = timer
          timer.add(to: .main, forMode: .common)
        } catch { if stamp == gen && !Task.isCancelled { fail(error) } }
      }
    }
    enum Signal: Error { case denied, hdr, failed }
    static func wide(_ map: [String: Any]) -> Bool {
      let transfer = (map[kCVImageBufferTransferFunctionKey as String] as? String ?? "")
        .lowercased()
      let prim = (map[kCVImageBufferColorPrimariesKey as String] as? String ?? "").lowercased()
      return transfer.contains("2084") || transfer.contains("hlg") || transfer.contains("2100")
        || prim.contains("2020") || prim.contains("p3")
        || map["MasteringDisplayColorVolume"] != nil || map["ContentLightLevelInfo"] != nil
    }
    static func dolby(_ f: FourCharCode) -> Bool {
      [0x6476_6831, 0x6476_6865, 0x6476_6131, 0x6476_6176].contains(f)
    }
    func stop() {
      stamp = UUID()
      active = false
      busy = false
      task?.cancel()
      task = nil
      link?.invalidate()
      link = nil
      if let item, let output { item.remove(output) }
      output = nil
      item = nil
      targets = nil
      shape = []
      cache = nil
      queue = nil
      gpu = nil
      view?.layer.opacity = 0
      lastFrame = 0
      lastDisplay = .invalid
    }
    private func fail(_ error: Error) {
      let msg: String
      switch error {
      case Signal.denied: msg = "受保护的视频使用原画"
      case Signal.hdr: msg = "此色彩格式使用原画"
      case UpscaleGraph.Failure.limit: msg = "画面超过处理容量，已使用原画"
      default: msg = "当前无法使用超分辨率，已使用原画"
      }
      // Preserve the bound item and mode so a periodic SwiftUI update does not retry in a loop.
      let failedItem = item
      let failedMode = mode
      stop()
      item = failedItem
      mode = failedMode
      state?.status(msg)
    }
    @objc private func frame() {
      guard active, let v = view, let player, let item, player.currentItem === item, let output,
        let gpu, let cache, let queue
      else { return }
      let now = CACurrentMediaTime()
      if player.isExternalPlaybackActive || v.window == nil {
        v.layer.opacity = 0
        return
      }
      if lastDisplay.isValid {
        let delta = abs(item.currentTime().seconds - lastDisplay.seconds)
        if !delta.isFinite || delta > 0.5 && (player.rate == 0 || now - lastFrame > 0.45) {
          v.layer.opacity = 0
        }
      }
      if now - started > 3 && lastFrame == 0 && player.timeControlStatus == .playing {
        state?.status("当前没有可处理的视频帧，正在显示原画")
      }
      guard !busy, v.drawableSize.width > 1, v.drawableSize.height > 1 else { return }
      let t = PresentationSession.time(for: player, host: now) ?? output.itemTime(forHostTime: now)
      guard output.hasNewPixelBuffer(forItemTime: t) else { return }
      var display = CMTime.invalid
      guard let buffer = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &display) else {
        v.layer.opacity = 0
        return
      }
      let metadata = CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any] ?? [:]
      guard !Self.wide(metadata) else {
        fail(Signal.hdr)
        return
      }
      guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
        fail(Signal.failed)
        return
      }
      let w = CVPixelBufferGetWidth(buffer)
      let h = CVPixelBufferGetHeight(buffer)
      let dw = Double(v.drawableSize.width)
      let dh = Double(v.drawableSize.height)
      let displaySize = item.presentationSize
      let rotated = abs(affine.b) > abs(affine.a)
      let sw = displaySize.width > 0 ? Double(displaySize.width) : Double(rotated ? h : w)
      let sh = displaySize.height > 0 ? Double(displaySize.height) : Double(rotated ? w : h)
      let factor = gravity == "fill" ? max(dw / sw, dh / sh) : min(dw / sw, dh / sh)
      let ow = gravity == "stretch" ? dw : sw * factor
      let oh = gravity == "stretch" ? dh : sh * factor
      guard ow.isFinite && oh.isFinite && ow <= 16384 && oh <= 16384 else {
        fail(UpscaleGraph.Failure.limit)
        return
      }
      let key = [
        w, h, max(1, Int((rotated ? oh : ow).rounded())),
        max(1, Int((rotated ? ow : oh).rounded())),
      ]
      var cv: CVMetalTexture?
      guard
        CVMetalTextureCacheCreateTextureFromImage(
          kCFAllocatorDefault, cache, buffer, nil, .bgra8Unorm, w, h, 0, &cv) == kCVReturnSuccess,
        let cv, let src = CVMetalTextureGetTexture(cv)
      else {
        fail(Signal.failed)
        return
      }
      do {
        if shape != key || targets == nil {
          targets = nil
          targets = try UpscaleTargets(
            gpu, mode: mode, w: w, h: h, outputW: key[2], outputH: key[3])
          shape = key
        }
        guard let targets, let pass = v.currentRenderPassDescriptor, let draw = v.currentDrawable,
          let cmd = queue.makeCommandBuffer()
        else {
          v.layer.opacity = 0
          return
        }
        let clean = CVImageBufferGetCleanRect(buffer)
        let uv = Self.coordinates(w: w, h: h, clean: clean, transform: affine)
        try targets.encode(
          cmd, gpu: gpu, source: src, pass: pass, extent: .init(Float(ow / dw), Float(oh / dh)),
          uv: uv)
        let gen = stamp
        busy = true
        let kept = FrameStorage(buffer, cv)
        let delivered = display
        cmd.present(draw)
        cmd.addCompletedHandler { [weak self] result in
          // The CV texture owns the backing surface; do not recycle it while the GPU is reading.
          withExtendedLifetime(kept) {}
          let success = result.status == .completed
          Task { @MainActor in
            guard let self, self.stamp == gen else { return }
            self.busy = false
            guard success else {
              self.fail(Signal.failed)
              return
            }
            self.lastFrame = CACurrentMediaTime()
            self.lastDisplay = delivered
            guard self.player?.currentItem === self.item, !player.isExternalPlaybackActive,
              !delivered.isValid || abs(item.currentTime().seconds - delivered.seconds) < 0.5
            else {
              self.view?.layer.opacity = 0
              return
            }
            self.view?.layer.opacity = 1
            self.state?.status(nil)
          }
        }
        cmd.commit()
      } catch { fail(error) }
    }
    static func coordinates(w: Int, h: Int, clean: CGRect, transform: CGAffineTransform) -> [SIMD2<
      Float
    >] {
      let full = CGRect(x: 0, y: 0, width: w, height: h)
      let crop = clean.intersection(full)
      let rect = (crop.isEmpty || crop.isNull ? full : crop).applying(transform)
      let inv = transform.inverted()
      func uv(_ x: Double, _ y: Double) -> SIMD2<Float> {
        let p = CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y).applying(inv)
        return .init(Float(p.x / CGFloat(w)), Float(p.y / CGFloat(h)))
      }
      let origin = uv(0, 0)
      return [origin, uv(1, 0) - origin, uv(0, 1) - origin]
    }
  }
}
