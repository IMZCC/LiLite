import CMPV
import CoreVideo
import OpenGLES
import QuartzCore
import SwiftUI
import UIKit

/// One render context per player, multiple short-lived drawable surfaces during fullscreen animation.
/// Every GL call runs on this queue; callbacks only signal a coalescing dispatch source.
final class MPVRenderer: @unchecked Sendable {
  private let core: MPVCore
  private let queue = DispatchQueue(label: "pili.mpv.render", qos: .userInteractive)
  private var gl: EAGLContext?
  private var context: OpaquePointer?
  private var updates: DispatchSourceUserDataAdd?
  private var surfaces: [UUID: Surface] = [:]
  private var suspended = false
  private var closed = false
  private var textureCache: CVOpenGLESTextureCache?
  private var frames: MPVPiPFrames?
  private final class Surface {
    let layer: CAEAGLLayer
    var fbo: GLuint = 0
    var color: GLuint = 0
    var width: GLint = 0
    var height: GLint = 0
    var dirty = true
    init(_ layer: CAEAGLLayer) { self.layer = layer }
  }
  init(core: MPVCore, active: Bool) {
    self.core = core
    suspended = !active
    let source = DispatchSource.makeUserDataAddSource(queue: queue)
    source.setEventHandler { [weak self] in self?.draw() }
    updates = source
    source.resume()
  }
  private func initialize() -> Bool {
    if context != nil { return true }
    guard let handle = core.handle else { return false }
    let result: Int32
    if suspended {
      result = pili_mpv_create_software_renderer(handle, &context)
    } else {
      guard let gl = EAGLContext(api: .openGLES3) ?? EAGLContext(api: .openGLES2) else { return false }
      self.gl = gl
      EAGLContext.setCurrent(gl)
      result = pili_mpv_create_renderer(handle, &context)
      CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, gl, nil, &textureCache)
    }
    guard result >= 0, let context else { core.renderFailed(result); return false }
    mpv_render_context_set_update_callback(context, { raw in
      guard let raw else { return }
      Unmanaged<MPVRenderer>.fromOpaque(raw).takeUnretainedValue().updates?.add(data: 1)
    }, Unmanaged.passUnretained(self).toOpaque())
    return true
  }
  func attach(_ id: UUID, layer: CAEAGLLayer) {
    queue.async { [self] in
      guard !closed else { return }
      surfaces[id] = Surface(layer)
      draw(force: true)
    }
  }
  func resize(_ id: UUID) {
    queue.async { [self] in surfaces[id]?.dirty = true; draw(force: true) }
  }
  func detach(_ id: UUID) {
    queue.async { [self] in
      guard let surface = surfaces.removeValue(forKey: id) else { return }
      if !suspended { EAGLContext.setCurrent(gl); destroy(surface); EAGLContext.setCurrent(nil) }
    }
  }
  private func destroy(_ surface: Surface) {
    if surface.fbo != 0 { glDeleteFramebuffers(1, &surface.fbo) }
    if surface.color != 0 { glDeleteRenderbuffers(1, &surface.color) }
    surface.fbo = 0
    surface.color = 0
    surface.dirty = true
  }
  private func draw(force: Bool = false) {
    guard !closed, context != nil || !surfaces.isEmpty || frames?.active == true, initialize(), let context else { return }
    if !suspended { EAGLContext.setCurrent(gl) }
    defer { if !suspended { EAGLContext.setCurrent(nil) } }
    let flags = mpv_render_context_update(context)
    guard force || flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
    if suspended {
      // Never submit GL work while inactive/backgrounded. VideoToolbox-copy still decodes
      // in hardware; libmpv's SW renderer scales/converts directly into our small PiP lease.
      if let frames, let buffer = frames.next(force: force) {
        CVPixelBufferLockBaseAddress(buffer, [])
        let result = pili_mpv_render_software(context, CVPixelBufferGetBaseAddress(buffer),
          Int32(CVPixelBufferGetWidth(buffer)), Int32(CVPixelBufferGetHeight(buffer)), CVPixelBufferGetBytesPerRow(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        if result >= 0 { frames.enqueue(buffer) }
      } else { pili_mpv_skip_render(context) }
      mpv_render_context_report_swap(context)
      return
    }
    guard let gl else { return }
    var fed = false
    for surface in surfaces.values {
      if surface.dirty {
        destroy(surface)
        glGenFramebuffers(1, &surface.fbo)
        glGenRenderbuffers(1, &surface.color)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), surface.color)
        guard gl.renderbufferStorage(Int(GL_RENDERBUFFER), from: surface.layer) else { continue }
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_WIDTH), &surface.width)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_HEIGHT), &surface.height)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), surface.fbo)
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), surface.color)
        surface.dirty = false
      }
      guard surface.width > 0, surface.height > 0 else { continue }
      glBindFramebuffer(GLenum(GL_FRAMEBUFFER), surface.fbo)
      guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE) else { continue }
      pili_mpv_render(context, Int32(surface.fbo), surface.width, surface.height)
      // Copy before presentRenderbuffer discards the drawable backing. ES3 blit avoids
      // a second mpv shader/render pass, and leaves the original on-screen path unchanged.
      if !fed { feed(surface, force: force); fed = true }
      glBindRenderbuffer(GLenum(GL_RENDERBUFFER), surface.color)
      gl.presentRenderbuffer(Int(GL_RENDERBUFFER))
    }
    if !fed {
      if frames?.active == true { feed(nil, force: force) }
      else { pili_mpv_skip_render(context) }
    }
    mpv_render_context_report_swap(context)
  }
  private func feed(_ surface: Surface?, force: Bool) {
    guard let frames, let cache = textureCache, let context, let buffer = frames.next(force: force) else { return }
    let w = Int32(CVPixelBufferGetWidth(buffer))
    let h = Int32(CVPixelBufferGetHeight(buffer))
    var texture: CVOpenGLESTexture?
    guard CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil,
      GLenum(GL_TEXTURE_2D), GL_RGBA, w, h, GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE), 0, &texture) == kCVReturnSuccess,
      let texture else { return }
    var fbo: GLuint = 0
    glGenFramebuffers(1, &fbo)
    defer { glDeleteFramebuffers(1, &fbo) }
    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
    glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), CVOpenGLESTextureGetName(texture), 0)
    guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE) else { return }
    if gl?.api == .openGLES3, let surface {
      glDisable(GLenum(GL_SCISSOR_TEST))
      glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), surface.fbo)
      glReadBuffer(GLenum(GL_COLOR_ATTACHMENT0))
      glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), fbo)
      // A drawable has a bottom-left origin; CVPixelBuffer scanlines start at the top.
      glBlitFramebuffer(0, surface.height, surface.width, 0, 0, 0, w, h, GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_LINEAR))
    } else {
      pili_mpv_render_buffer(context, Int32(fbo), w, h)
    }
    glFinish()
    frames.enqueue(buffer)
    CVOpenGLESTextureCacheFlush(cache, 0)
  }
  func configurePiP(_ frames: MPVPiPFrames, source: CGSize, render: CGSize, active: Bool, enabled: Bool) {
    queue.async { [self] in
      guard !closed else { return }
      let changed = self.frames !== frames || frames.enabled != enabled || frames.sourceSize != source || frames.renderSize != render
      self.frames = frames
      frames.sourceSize = source
      frames.renderSize = render
      frames.active = active
      frames.enabled = enabled
      if changed && enabled { draw(force: true) }
    }
  }
  func resetPiP() { queue.async { [self] in frames?.reset() } }
  func refreshPiP() { queue.async { [self] in draw(force: true) } }
  func setSuspended(_ value: Bool) {
    // Complete and release all GPU resources BEFORE willResignActive returns.
    // mpv allows one context per core, so replace it and reselect vid on the client queue.
    queue.sync {
      guard suspended != value, !closed else { return }
      releaseContext()
      suspended = value
      _ = initialize()
      if !value { EAGLContext.setCurrent(nil) }
    }
  }
  func close(_ completion: @escaping () -> Void) {
    queue.async { [self] in
      guard !closed else { return }
      closed = true
      releaseContext()
      frames?.reset()
      frames = nil
      surfaces.removeAll()
      updates?.cancel()
      updates = nil
      completion()
    }
  }
  private func releaseContext() {
    if let gl { EAGLContext.setCurrent(gl) }
    if let context {
      mpv_render_context_set_update_callback(context, nil, nil)
      mpv_render_context_free(context)
    }
    context = nil
    if gl != nil {
      surfaces.values.forEach(destroy)
      textureCache = nil
      glFinish()
      EAGLContext.setCurrent(nil)
    }
    gl = nil
  }
}

struct MPVVideoView: UIViewRepresentable {
  let player: MPVPlayer
  var gravity = "fit"
  func makeUIView(context: Context) -> SurfaceView {
    let view = SurfaceView(player: player)
    view.configure(size: player.playbackSize, gravity: gravity)
    return view
  }
  func updateUIView(_ view: SurfaceView, context: Context) { view.configure(size: player.playbackSize, gravity: gravity) }
  static func dismantleUIView(_ view: SurfaceView, coordinator: ()) { view.disconnect() }
  final class SurfaceView: UIView {
    private let renderer: MPVRenderer
    private weak var player: MPVPlayer?
    private let drawable = CAEAGLLayer()
    private let id = UUID()
    private var attached = false
    private var lastSize = CGSize.zero
    private var sourceSize = CGSize.zero
    private var gravity = "fit"
    init(player: MPVPlayer) {
      self.renderer = player.renderer
      self.player = player
      super.init(frame: .zero)
      isOpaque = true
      backgroundColor = .black
      clipsToBounds = true
      isUserInteractionEnabled = false
      // The real scale comes from the window's own screen once attached (didMoveToWindow).
      contentScaleFactor = max(1, traitCollection.displayScale)
      drawable.isOpaque = true
      drawable.contentsScale = contentScaleFactor
      drawable.drawableProperties = [kEAGLDrawablePropertyRetainedBacking: false,
        kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8]
      layer.addSublayer(drawable)
    }
    required init?(coder: NSCoder) { nil }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      // The screen this window is on, not UIScreen.main (iPhone Duo inner/outer, external display).
      if let scale = window?.screen.scale, scale > 0, drawable.contentsScale != scale {
        contentScaleFactor = scale
        drawable.contentsScale = scale
        lastSize = .zero
        setNeedsLayout()
      }
      if let window, !attached {
        attached = true
        player?.preparePiP(in: window)
        renderer.attach(id, layer: drawable)
      } else if window == nil { disconnect() }
    }
    override func layoutSubviews() {
      super.layoutSubviews()
      var rect = bounds
      if gravity != "stretch", sourceSize.width > 0, sourceSize.height > 0 {
        let x = bounds.width / sourceSize.width
        let y = bounds.height / sourceSize.height
        let scale = gravity == "fill" ? max(x, y) : min(x, y)
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
          width: size.width, height: size.height)
      }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      drawable.frame = rect
      CATransaction.commit()
      if rect.size != lastSize { lastSize = rect.size; renderer.resize(id) }
    }
    func configure(size: CGSize, gravity: String) {
      guard sourceSize != size || self.gravity != gravity else { return }
      sourceSize = size
      self.gravity = gravity
      setNeedsLayout()
    }
    func disconnect() { if attached { attached = false; renderer.detach(id) } }
  }
}
