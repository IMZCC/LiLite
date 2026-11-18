import AVKit
import SwiftUI

struct AutoTheater: ViewModifier {
  @ObservedObject var model: PlayerModel
  let cid: Int64?
  @Binding var presented: Bool
  var inheritPresentation = false
  @State private var inherited = false
  @State private var entered: Int64?
  @AppStorage("theater.autoEnter") private var enter = false
  @AppStorage("theater.autoExit") private var exit = true
  private struct Trigger: Equatable { let cid:Int64?,ready:Bool,playing:Bool,hasPlayed:Bool }
  func body(content: Content) -> some View {
    content.onChange(of: Trigger(cid:cid,ready:model.ready,playing:model.playing,hasPlayed:model.hasPlayed), initial:true) { previous,next in
      if previous.cid != next.cid { entered = nil }
      if model.ready, let cid, entered != cid,
        (enter && (model.playing || model.hasPlayed)) || (inheritPresentation && !inherited)
      {
        inherited = true
        entered = cid
        presented = true
      }
    }.onChange(of: model.finishedAt) { _, _ in if exit && presented { presented = false } }
  }
}
struct FullscreenSwipe: ViewModifier {
  let fullscreen: Bool, enabled: Bool, action: () -> Void
  @AppStorage("theater.swipe") private var swipe = true
  @AppStorage("theater.reverseSwipe") private var reverse = false
  func body(content: Content) -> some View {
    GeometryReader { g in
      content.simultaneousGesture(
        DragGesture(minimumDistance: 18).onEnded { v in
          if enabled && swipe
            && FullscreenMode.swipe(
              fullscreen: fullscreen, reverse: reverse, x: v.startLocation.x, width: g.size.width,
              dx: v.translation.width, dy: v.translation.height)
          {
            TouchFeedback.light()
            action()
          }
        })
    }
  }
}
@MainActor enum TheaterOrientation {
  struct Entry { let token: UUID, mask: UIInterfaceOrientationMask }
  static var byScene: [ObjectIdentifier: Entry] = [:]
  /// Fullscreen direction when the user has not chosen one: like the original, large screens
  /// (iPad, unfolded iPhone Duo) keep the current direction and smaller ones follow the video.
  static var defaultMode: Int {
    (WindowCanvas.shared.large ? FullscreenMode.keep : FullscreenMode.video).rawValue
  }
  static func allowed(_ window: UIWindow?) -> UIInterfaceOrientationMask {
    if let scene = window?.windowScene, let mask = byScene[ObjectIdentifier(scene)]?.mask { return mask }
    return (window?.traitCollection.userInterfaceIdiom ?? UIDevice.current.userInterfaceIdiom) == .pad ? .all : .allButUpsideDown
  }
}
struct TheaterGeometry: UIViewControllerRepresentable {
  let mode: FullscreenMode, size: CGSize
  func makeUIViewController(context: Context) -> Probe { Probe() }
  func updateUIViewController(_ p: Probe, context: Context) {
    p.mode = mode
    p.size = size
    p.apply()
  }
  static func dismantleUIViewController(_ p: Probe, coordinator: ()) { p.releaseScene() }
  final class Probe: UIViewController {
    let token = UUID()
    var mode = FullscreenMode.keep, size = CGSize.zero
    private weak var scene: UIWindowScene?
    private var original: UIInterfaceOrientation?
    private var last: UIInterfaceOrientationMask?
    private var visible = false
    override func loadView() {
      view = UIView()
      view.isUserInteractionEnabled = false
    }
    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      visible = true
      apply()
    }
    override func viewDidDisappear(_ animated: Bool) {
      visible = false
      super.viewDidDisappear(animated)
    }
    func apply() {
      guard visible, let w = viewIfLoaded?.window, let s = w.windowScene else { return }
      if scene !== s {
        releaseScene()
        scene = s
        original = s.interfaceOrientation
        TheaterExit.original[ObjectIdentifier(s)] = s.interfaceOrientation
      }
      let bounds = s.screen.bounds.size
      guard
        let wanted = mode.wanted(
          videoWidth: size.width, videoHeight: size.height, screenWidth: bounds.width,
          screenHeight: bounds.height)
      else {
        if last != nil { releaseScene() }
        return
      }
      let mask: UIInterfaceOrientationMask = wanted == .landscape ? .landscape : .portrait
      guard mask != last else { return }
      last = mask
      TheaterOrientation.byScene[ObjectIdentifier(s)] = .init(token: token, mask: mask)
      top(w.rootViewController)?.setNeedsUpdateOfSupportedInterfaceOrientations()
      s.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self, weak s] _ in
        guard let self, let s, TheaterOrientation.byScene[ObjectIdentifier(s)]?.token == self.token,
          self.last == mask
        else { return }
        TheaterOrientation.byScene[ObjectIdentifier(s)] = nil
      }
    }
    func top(_ c: UIViewController?) -> UIViewController? {
      if let p = c?.presentedViewController { return top(p) }
      return c
    }
    func releaseScene() {
      guard let s = scene else { return }
      defer {
        scene = nil
        last = nil
        original = nil
      }
      guard TheaterOrientation.byScene[ObjectIdentifier(s)]?.token == token else { return }
      TheaterOrientation.byScene[ObjectIdentifier(s)] = nil
      for w in s.windows where w.isKeyWindow {
        top(w.rootViewController)?.setNeedsUpdateOfSupportedInterfaceOrientations()
      }
      let mask: UIInterfaceOrientationMask
      switch original {
      case .portrait: mask = .portrait
      case .landscapeRight: mask = .landscapeRight
      case .landscapeLeft: mask = .landscapeLeft
      default: return
      }
      s.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
  }
}

/// Leaving fullscreen rotates back to portrait while fullscreen still covers the page, then
/// closes it. Closing first would show the page laid out sideways for the length of the
/// rotation (and re-lay it out twice); this way the page only ever appears upright.
@MainActor enum TheaterExit {
  static var original: [ObjectIdentifier: UIInterfaceOrientation] = [:]
  static func restore(then done: @escaping @MainActor () -> Void) {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    guard UIDevice.current.userInterfaceIdiom == .phone, !WindowCanvas.shared.large, let s = scene,
      s.interfaceOrientation.isLandscape,
      (original[ObjectIdentifier(s)] ?? .portrait) == .portrait
    else {
      done()
      return
    }
    let id = ObjectIdentifier(s)
    let token = UUID()
    TheaterOrientation.byScene[id] = .init(token: token, mask: .portrait)
    for w in s.windows where w.isKeyWindow { top(w.rootViewController)?.setNeedsUpdateOfSupportedInterfaceOrientations() }
    s.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
    Task { @MainActor in
      // The system rotation takes about 0.4 s.
      try? await Task.sleep(for: .milliseconds(430))
      done()
      // A page that holds portrait takes the lock over; otherwise free the orientation again.
      try? await Task.sleep(for: .seconds(1.5))
      if TheaterOrientation.byScene[id]?.token == token {
        TheaterOrientation.byScene[id] = nil
        for w in s.windows where w.isKeyWindow { top(w.rootViewController)?.setNeedsUpdateOfSupportedInterfaceOrientations() }
      }
    }
  }
  private static func top(_ c: UIViewController?) -> UIViewController? {
    if let p = c?.presentedViewController { return top(p) }
    return c
  }
}

/// iPhone detail pages stay portrait. Turning the phone sideways opens fullscreen and turning it
/// back closes it again, as in the original client. Opening by rotation never animates the
/// cover, so the only motion is the system's own rotation.
struct RotateToFullscreen: ViewModifier {
  @Binding var theater: Bool
  let enabled: Bool
  @State private var byRotation = false
  func body(content: Content) -> some View {
    content
      .background(PortraitLock(active: enabled && !theater).allowsHitTesting(false))
      .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
        follow(UIDevice.current.orientation)
      }
      .onChange(of: theater) { _, open in if !open { byRotation = false } }
      .onChange(of: enabled) { _, _ in follow(UIDevice.current.orientation) }
      .onAppear {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        follow(UIDevice.current.orientation)
      }
      .onDisappear { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
  }
  private func follow(_ o: UIDeviceOrientation) {
    guard enabled else { return }
    if o.isLandscape, !theater {
      byRotation = true
      theater = true
    } else if o == .portrait, theater, byRotation {
      byRotation = false
      theater = false
    }
  }
}

/// Holds the scene in portrait while active (shares `TheaterOrientation` with fullscreen, which
/// takes over while it is shown).
struct PortraitLock: UIViewControllerRepresentable {
  let active: Bool
  func makeUIViewController(context: Context) -> Probe { Probe() }
  func updateUIViewController(_ p: Probe, context: Context) {
    p.active = active
    p.apply()
  }
  static func dismantleUIViewController(_ p: Probe, coordinator: ()) { p.release() }
  final class Probe: UIViewController {
    let token = UUID()
    var active = false
    private weak var scene: UIWindowScene?
    private var visible = false
    override func loadView() {
      view = UIView()
      view.isUserInteractionEnabled = false
    }
    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      visible = true
      apply()
    }
    override func viewDidDisappear(_ animated: Bool) {
      visible = false
      release()
      super.viewDidDisappear(animated)
    }
    func apply() {
      guard visible, active, let w = viewIfLoaded?.window, let s = w.windowScene,
        w.traitCollection.userInterfaceIdiom == .phone, !WindowCanvas.isLarge(w.bounds.size)
      else {
        release()
        return
      }
      if TheaterOrientation.byScene[ObjectIdentifier(s)]?.token == token { return }
      scene = s
      TheaterOrientation.byScene[ObjectIdentifier(s)] = .init(token: token, mask: .portrait)
      top(w.rootViewController)?.setNeedsUpdateOfSupportedInterfaceOrientations()
      if s.interfaceOrientation != .portrait {
        s.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
      }
    }
    func release() {
      guard let s = scene else { return }
      scene = nil
      guard TheaterOrientation.byScene[ObjectIdentifier(s)]?.token == token else { return }
      TheaterOrientation.byScene[ObjectIdentifier(s)] = nil
      for w in s.windows where w.isKeyWindow {
        top(w.rootViewController)?.setNeedsUpdateOfSupportedInterfaceOrientations()
      }
    }
    private func top(_ c: UIViewController?) -> UIViewController? {
      if let p = c?.presentedViewController { return top(p) }
      return c
    }
  }
}
