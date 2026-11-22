import CMPV
import Combine
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
  private var pageReleased = false
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
    guard let handle = core.renderHandle() else { return false }
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
  /// Has mpv's render context made before a file is opened, whether or not a drawable has
  /// reached the window yet. libmpv's video output only starts against an existing context: a
  /// page that began loading first (a second video opened right after leaving one) got a failed
  /// video output, its sound and clock running over a black picture. The client queue waits on
  /// the returned group before `loadfile`.
  func prepareForLoad() -> DispatchGroup {
    let ready = DispatchGroup()
    ready.enter()
    queue.async { [self] in
      defer { ready.leave() }
      guard !closed, !pageReleased else { return }
      _ = initialize()
      if !suspended { EAGLContext.setCurrent(nil) }
    }
    return ready
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
    guard !closed, !pageReleased, context != nil || !surfaces.isEmpty || frames?.active == true,
      initialize(), let context else { return }
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
      }
      // A storage taken while the layer had no size, or one that came out incomplete, stays to
      // be made again on the next frame. Marked clean on allocation, such a drawable was skipped
      // for the rest of playback: the sound and the bullets ran over a black picture.
      guard surface.width > 0, surface.height > 0 else { surface.dirty = true; continue }
      glBindFramebuffer(GLenum(GL_FRAMEBUFFER), surface.fbo)
      guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
        surface.dirty = true
        continue
      }
      pili_mpv_render(context, Int32(surface.fbo), surface.width, surface.height)
      // Copy before presentRenderbuffer discards the drawable backing. ES3 blit avoids
      // a second mpv shader/render pass, and leaves the original on-screen path unchanged.
      if !fed { feed(surface, force: force); fed = true }
      glBindRenderbuffer(GLenum(GL_RENDERBUFFER), surface.color)
      surface.dirty = !gl.presentRenderbuffer(Int(GL_RENDERBUFFER))
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
    if gl?.api == .openGLES3, let surface, surface.height > 0,
      abs(Double(surface.width) * Double(h) - Double(w) * Double(surface.height)) <= Double(max(h, surface.height)) {
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
  /// A covered navigation page can stay alive after playback has stopped. Drop its render
  /// targets, then recreate the context on the render queue if that player is used again.
  func setPageReleased(_ released: Bool) {
    queue.async { [self] in
      guard !closed, pageReleased != released else { return }
      pageReleased = released
      if released { releaseContext() } else { draw(force: true) }
    }
  }
  func setSuspended(_ value: Bool) {
    // Complete and release all GPU resources BEFORE willResignActive returns.
    // mpv allows one context per core, so replace it and reselect vid on the client queue.
    queue.sync {
      guard suspended != value, !closed else { return }
      releaseContext()
      suspended = value
      guard !pageReleased else { return }
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
  /// Views of one player that share a slot hand a single drawable from one to the next instead
  /// of each starting with a black one. The page's own player is rebuilt whenever the page
  /// switches layouts (an iPhone Duo folding or unfolding, a window resized across a threshold),
  /// and a new drawable stays black until the renderer has drawn into it (~150 ms). `nil`
  /// keeps a drawable of its own (fullscreen, which animates beside the page's player).
  var slot: String? = nil
  func makeUIView(context: Context) -> Host {
    Host(player: player, slot: slot, gravity: gravity)
  }
  func updateUIView(_ host: Host, context: Context) { host.configure(gravity: gravity) }
  static func dismantleUIView(_ host: Host, coordinator: ()) { host.release() }

  /// The drawable shared by a player's views in one slot, and those views.
  @MainActor private final class Shared {
    struct Entry { weak var host: Host? }
    var surface: SurfaceView?
    /// Oldest first.
    var hosts: [Entry] = []
    var live: [Host] { hosts.compactMap(\.host) }
  }
  /// Keyed by the player itself, weakly: the groups go with it, and a later player can never
  /// find an earlier one's drawable at a reused address.
  @MainActor private final class Slots { var named: [String: Shared] = [:] }
  @MainActor private static let groups = NSMapTable<MPVPlayer, Slots>.weakToStrongObjects()
  @MainActor private static func group(_ player: MPVPlayer, _ slot: String, create: Bool) -> Shared? {
    let slots = groups.object(forKey: player) ?? (create ? Slots() : nil)
    guard let slots else { return nil }
    if groups.object(forKey: player) == nil { groups.setObject(slots, forKey: player) }
    if let found = slots.named[slot] { return found }
    guard create else { return nil }
    let made = Shared()
    slots.named[slot] = made
    return made
  }
  @MainActor private static func drop(_ player: MPVPlayer?, _ slot: String) {
    guard let player, let slots = groups.object(forKey: player) else { return }
    slots.named[slot] = nil
    if slots.named.isEmpty { groups.removeObject(forKey: player) }
  }

  /// Where SwiftUI puts the picture. The drawable inside is this host's own, or the one its slot
  /// shares, taken over from the host it was in when this one reaches a window.
  final class Host: UIView {
    /// Weak, as the drawable's own: a view UIKit keeps for a moment must not keep the player.
    private weak var player: MPVPlayer?
    private let slot: String?
    /// The slot's group, held here too so a host can hand its drawable on after the player went.
    private var held: Shared?
    private var gravity: String
    private var own: SurfaceView?
    init(player: MPVPlayer, slot: String?, gravity: String) {
      self.player = player
      self.gravity = gravity
      self.slot = slot
      super.init(frame: .zero)
      isOpaque = true
      backgroundColor = .black
      clipsToBounds = true
      isUserInteractionEnabled = false
      if let slot, let group = MPVVideoView.group(player, slot, create: true) {
        held = group
        group.hosts = group.hosts.filter { $0.host != nil } + [Shared.Entry(host: self)]
      } else {
        let own = SurfaceView(player: player)
        own.configure(size: player.playbackSize, gravity: gravity)
        addSubview(own)
        self.own = own
      }
    }
    required init?(coder: NSCoder) { nil }
    private var group: Shared? { held }
    private var surface: SurfaceView? { own ?? group?.surface }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window != nil { claim() }
    }
    override func layoutSubviews() {
      super.layoutSubviews()
      if let surface, surface.superview === self { surface.frame = bounds }
    }
    func configure(gravity: String) {
      self.gravity = gravity
      if let player, let surface, surface.superview === self {
        surface.configure(size: player.playbackSize, gravity: gravity)
      }
    }
    /// On screen: the slot's drawable moves here, still showing the last picture.
    private func claim() {
      guard let group, let player else { return }
      let surface = group.surface ?? SurfaceView(player: player)
      group.surface = surface
      guard surface.superview !== self else { return }
      adopt(surface)
    }
    fileprivate func adopt(_ surface: SurfaceView) {
      // Sized before it joins: its window callback attaches it and asks for a frame at once.
      surface.frame = bounds
      addSubview(surface)
      if let player { surface.configure(size: player.playbackSize, gravity: gravity) }
    }
    /// Gone from the page: its drawable goes on to the newest other view of the slot (the one
    /// replacing it, which may not have reached the window yet), or is let go with the last one.
    func release() {
      guard let slot, let group else { own?.disconnect(); return }
      held = nil
      group.hosts.removeAll { $0.host == nil || $0.host === self }
      guard let surface = group.surface, surface.superview === self else {
        if group.live.isEmpty {
          group.surface?.removeFromSuperview()
          group.surface?.disconnect()
          group.surface = nil
          MPVVideoView.drop(player, slot)
        }
        return
      }
      let others = group.live
      if let next = others.last(where: { $0.window != nil }) ?? others.last {
        next.adopt(surface)
      } else {
        surface.removeFromSuperview()
        surface.disconnect()
        group.surface = nil
        MPVVideoView.drop(player, slot)
      }
    }
  }
  final class SurfaceView: UIView {
    private let renderer: MPVRenderer
    private weak var player: MPVPlayer?
    private let drawable = CAEAGLLayer()
    private let id = UUID()
    private var attached = false
    private var sizeWatch: AnyCancellable?
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
      sizeWatch = player.statePublisher.merge(with: player.itemPublisher.map { _ in () })
        .map { [weak player] in player?.playbackSize ?? .zero }
        .removeDuplicates()
        .sink { [weak self] size in
          guard let self else { return }
          self.configure(size: size, gravity: self.gravity)
        }
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
      } else if window != nil {
        // Back in a window while still attached (handed between views): its storage is taken
        // again from the layer at its next layout rather than trusted.
        lastSize = .zero
        setNeedsLayout()
      } else if window == nil {
        // Handed between views, the drawable is out of any window for a moment (the old view
        // leaves before the new one arrives): it stays attached, still showing its picture,
        // unless it stays out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
          guard let self, self.window == nil else { return }
          self.disconnect()
        }
      }
    }
    override func layoutSubviews() {
      super.layoutSubviews()
      var raster = bounds.size
      let hasSource = sourceSize.width > 0 && sourceSize.height > 0
      if hasSource {
        let x = bounds.width / sourceSize.width, y = bounds.height / sourceSize.height
        let scale = gravity == "fill" ? max(x, y) : min(x, y)
        raster = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
      }
      // The framebuffer always keeps the display aspect. Only an explicit stretch changes
      // its on-screen transform; the decoder and the PiP copy retain the original geometry.
      var transform = CGAffineTransform.identity
      if gravity == "stretch", raster.width > 0, raster.height > 0 {
        transform = CGAffineTransform(scaleX: bounds.width / raster.width, y: bounds.height / raster.height)
      }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      drawable.bounds = CGRect(origin: .zero, size: raster)
      drawable.position = CGPoint(x: bounds.midX, y: bounds.midY)
      drawable.setAffineTransform(transform)
      CATransaction.commit()
      if raster != lastSize { lastSize = raster; renderer.resize(id) }
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
