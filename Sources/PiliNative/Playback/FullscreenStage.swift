import SwiftUI
import UIKit

private struct CoveredInlinePlayer: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
  var inlinePlayerCovered: Bool {
    get { self[CoveredInlinePlayer.self] }
    set { self[CoveredInlinePlayer.self] = newValue }
  }
}

/// The fullscreen cover must appear and leave in place: the only motion is the picture moving
/// with the system rotation. SwiftUI still slides a full-screen cover in and out inside a
/// transaction that disables animations (seen on iOS 27). The slide delayed the rotation by half a
/// second and showed the fullscreen controls laid out upright, so UIKit animations are held off
/// from the request until the cover has appeared or gone, with a timeout as a backstop.
@MainActor enum CoverTransition {
  private static var held = false
  private static var ticket = 0
  static func hold() {
    ticket += 1
    let mine = ticket
    if !held {
      held = true
      UIView.setAnimationsEnabled(false)
    }
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(900))
      if ticket == mine { release() }
    }
  }
  static func release() {
    guard held else { return }
    held = false
    UIView.setAnimationsEnabled(true)
  }
}

private struct TheaterCover<Destination: View>: ViewModifier {
  @Binding var requested: Bool
  let player: any PlaybackEngine
  @Binding var covering: Bool
  @ViewBuilder var destination: (InlinePlayerFrame.Snapshot?) -> Destination
  @State private var presented = false
  @State private var entry: InlinePlayerFrame.Snapshot?

  func body(content: Content) -> some View {
    content.environment(\.inlinePlayerCovered, presented && (covering || !requested))
      .onChange(of: requested, initial: true) { _, open in
        guard open, !presented else { return }
        entry = InlinePlayerFrame.current(player)
        CoverTransition.hold()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { presented = true }
      }
      .piliFullScreenCover(isPresented: $presented, onDismiss: {
        CoverTransition.release()
        covering = false
        requested = false
        entry = nil
      }) { destination(entry) }
  }
}

extension View {
  func theaterCover<Destination: View>(requested: Binding<Bool>, player: any PlaybackEngine,
    covering: Binding<Bool>, @ViewBuilder destination: @escaping (InlinePlayerFrame.Snapshot?) -> Destination
  ) -> some View {
    modifier(TheaterCover(requested: requested, player: player, covering: covering, destination: destination))
  }
}

/// UIKit animates the clip and the center/scale of one mounted player. The drawable is
/// laid out at the destination resolution once, even while the scene itself is rotating.
struct FullscreenStage<Content: View>: UIViewControllerRepresentable {
  let mode: FullscreenMode, picture: CGSize
  let entry: InlinePlayerFrame.Snapshot?
  let closing: Bool
  let inline: () -> InlinePlayerFrame.Snapshot?
  let covered: (Bool) -> Void
  let finish: () -> Void
  @ViewBuilder let content: () -> Content

  func makeUIViewController(context: Context) -> FullscreenStageController { FullscreenStageController() }
  func updateUIViewController(_ c: FullscreenStageController, context: Context) {
    c.host.rootView = AnyView(content().environment(\.self, context.environment))
    c.entry = entry
    c.inline = inline
    c.covered = covered
    c.finish = finish
    c.reduced = context.environment.accessibilityReduceMotion
    c.configure(mode: mode, picture: picture, closing: closing)
  }
  static func dismantleUIViewController(_ c: FullscreenStageController, coordinator: ()) { c.stop() }
}

@MainActor final class FullscreenStageController: UIViewController {
  let host = UIHostingController(rootView: AnyView(EmptyView()))
  var entry: InlinePlayerFrame.Snapshot?
  var inline: (() -> InlinePlayerFrame.Snapshot?)?
  var covered: ((Bool) -> Void)?
  var finish: (() -> Void)?
  var reduced = false
  private let backdrop = UIView(), viewport = UIView()
  private let orientation = PlaybackOrientation()
  private var mode = FullscreenMode.keep, picture = CGSize.zero
  private enum Phase { case inline, entering, full, exiting, finished }
  private var phase = Phase.inline
  private var wantsClose = false, visible = false, rotating = false
  private var generation = 0
  private var noResize: Task<Void, Never>?
  private var waitingSize: CGSize?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    backdrop.backgroundColor = .black
    backdrop.alpha = 0
    backdrop.frame = view.bounds
    backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(backdrop)
    viewport.clipsToBounds = true
    viewport.backgroundColor = .black
    view.addSubview(viewport)
    addChild(host)
    host.view.backgroundColor = .black
    viewport.addSubview(host.view)
    host.didMove(toParent: self)
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard !rotating else { return }
    if let waitingSize, view.bounds.size != waitingSize {
      // Some window configurations resize the hosting view without forwarding
      // viewWillTransition. Join any live coordinator as soon as the new bounds arrive.
      self.waitingSize = nil
      animate(to: view.bounds.size, alongside: transitionCoordinator)
      return
    }
    switch phase {
    case .inline:
      let rect = inlineRect(for: view.bounds.size)
      place(at: rect, canvas: rect.size)
    case .full: place(at: view.bounds, canvas: view.bounds.size)
    default: break
    }
  }
  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    // The first layout pass runs before the cover is in a window; place the picture on the
    // inline player again now that its window coordinates mean something.
    view.setNeedsLayout()
    view.layoutIfNeeded()
  }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    // The cover is in place: the rotation and the picture's move must animate again.
    CoverTransition.release()
    guard !visible, let window = view.window else { return }
    visible = true
    orientation.attach(window, original: entry?.orientation)
    reconcile()
  }
  func configure(mode: FullscreenMode, picture: CGSize, closing: Bool) {
    guard self.mode != mode || self.picture != picture || wantsClose != closing else { return }
    self.mode = mode
    self.picture = picture
    wantsClose = closing
    // updateUIViewController can run in a SwiftUI view update.
    if visible { DispatchQueue.main.async { [weak self] in self?.reconcile() } }
  }
  private func reconcile() {
    guard visible, !rotating, phase != .finished else { return }
    if wantsClose && phase != .exiting { begin(exit: true) }
    else if !wantsClose && (phase == .inline || phase == .exiting) { begin(exit: false) }
    else if !wantsClose { _ = orientation.update(mode, picture: picture) }
  }
  private func begin(exit: Bool) {
    phase = exit ? .exiting : .entering
    generation += 1
    let ticket = generation
    noResize?.cancel()
    waitingSize = nil
    // Warm the inline output under the moving fullscreen viewport on the way back.
    covered?(!exit)
    let fallback = { [weak self] in
      guard let self, self.generation == ticket, !self.rotating else { return }
      self.animate(to: self.view.bounds.size, alongside: nil)
    }
    let requested = exit ? orientation.restore(denied: fallback)
      : orientation.update(mode, picture: picture, denied: fallback)
    if requested {
      guard generation == ticket else { return }
      waitingSize = view.bounds.size
      // Windowed scenes can accept a mask without resizing. Only that case needs a fallback.
      noResize = Task { @MainActor in
        do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
        fallback()
      }
    } else { fallback() }
  }
  override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
    super.viewWillTransition(to: size, with: coordinator)
    guard visible, phase != .finished else { return }
    noResize?.cancel()
    rotating = true
    animate(to: size, alongside: coordinator)
  }
  private func inlineRect(for size: CGSize) -> CGRect {
    // The first layout pass runs before the cover joins the window. The entry was sampled from
    // the presenting window just before, so it still says where the inline player is; without
    // it the picture would start out filling the screen.
    let window = view.window.map { ObjectIdentifier($0) }
    // During the rotation callback the inline view may still have the outgoing layout.
    // Use the recorded landing rect when returning to the original window dimensions.
    let source: InlinePlayerFrame.Snapshot?
    if let entry, window == nil || entry.window == window, entry.bounds.height > 0,
      abs(entry.bounds.width * size.height / entry.bounds.height - size.width) < 2 {
      source = entry
    } else if window != nil { source = inline?() } else { source = nil }
    guard let source, window == nil || source.window == window, source.bounds.width > 0,
      source.bounds.height > 0 else { return CGRect(origin: .zero, size: size) }
    return source.rect.applying(CGAffineTransform(scaleX: size.width / source.bounds.width,
      y: size.height / source.bounds.height))
  }
  private func fit(in size: CGSize) -> CGFloat {
    guard picture.width > 0, picture.height > 0 else { return max(1, size.width) }
    return max(0.0001, min(size.width / picture.width, size.height / picture.height))
  }
  private func place(at rect: CGRect, canvas: CGSize) {
    guard min(canvas.width, canvas.height, rect.width, rect.height) > 0 else { return }
    viewport.bounds = CGRect(origin: .zero, size: rect.size)
    viewport.center = CGPoint(x: rect.midX, y: rect.midY)
    host.view.bounds = CGRect(origin: .zero, size: canvas)
    host.view.center = CGPoint(x: rect.width / 2, y: rect.height / 2)
    let scale = fit(in: rect.size) / fit(in: canvas)
    host.view.transform = CGAffineTransform(scaleX: scale, y: scale)
  }
  private func animate(to size: CGSize, alongside coordinator: UIViewControllerTransitionCoordinator?) {
    noResize?.cancel()
    waitingSize = nil
    generation += 1
    let ticket = generation
    let exit = phase == .exiting
    let start = viewport.layer.presentation()?.frame ?? viewport.frame
    let target = exit ? inlineRect(for: size) : CGRect(origin: .zero, size: size)
    // Keep the landscape drawable throughout the shrink. On entry allocate it before
    // starting the layer animation, so mpv need not rebuild a framebuffer on every tick.
    let canvas = exit && host.view.bounds.width > 0 ? host.view.bounds.size : size
    UIView.performWithoutAnimation {
      place(at: start, canvas: canvas)
      host.view.layoutIfNeeded()
    }
    if !exit, coordinator != nil {
      // The page behind is laid out sideways for the rotation; hide it at once instead of
      // letting it show through for the whole turn. The picture alone carries the motion.
      UIView.animate(withDuration: reduced ? 0 : 0.12, delay: 0, options: [.beginFromCurrentState]) {
        self.backdrop.alpha = 1
      }
    }
    let changes = {
      self.place(at: target, canvas: canvas)
      self.backdrop.alpha = exit ? 0 : 1
    }
    let complete = { [weak self] in
      guard let self, self.generation == ticket, self.visible else { return }
      self.rotating = false
      if exit && self.wantsClose {
        self.phase = .finished
        // Leave in place as well: the picture already sits on the inline player.
        CoverTransition.hold()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { self.finish?() }
      } else {
        self.phase = exit ? .inline : .full
        self.view.setNeedsLayout()
        self.reconcile()
      }
    }
    if let coordinator, coordinator.animate(alongsideTransition: { _ in changes() }, completion: { context in
      if context.isCancelled && self.visible && self.generation == ticket {
        self.rotating = false
        self.animate(to: self.view.bounds.size, alongside: nil)
      } else { complete() }
    }) {
      return
    }
    UIView.animate(withDuration: reduced ? 0 : 0.28, delay: 0,
      options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction], animations: changes) { _ in complete() }
  }
  func stop() {
    visible = false
    generation += 1
    noResize?.cancel()
    orientation.release(restore: phase != .finished)
  }
}
