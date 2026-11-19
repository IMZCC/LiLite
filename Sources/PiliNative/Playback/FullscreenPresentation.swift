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
  static let ownerChanged = Notification.Name("PiliTheaterOrientationOwnerChanged")
  /// Posts `ownerChanged`, so a portrait lock that stepped aside for fullscreen takes the scene
  /// back as soon as fullscreen lets go of it.
  static var byScene: [ObjectIdentifier: Entry] = [:] {
    didSet { NotificationCenter.default.post(name: ownerChanged, object: nil) }
  }
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
/// The owner keeps its mask until the cover is gone, including the return rotation.
@MainActor final class PlaybackOrientation {
  private let token = UUID()
  private weak var scene: UIWindowScene?
  private var original: UIInterfaceOrientation = .unknown
  private var last: UIInterfaceOrientationMask?
  private var held: Bool { scene.map { TheaterOrientation.byScene[ObjectIdentifier($0)]?.token == token } ?? false }

  func attach(_ window: UIWindow, original: UIInterfaceOrientation? = nil) {
    guard let next = window.windowScene, scene !== next else { return }
    release(restore: true)
    scene = next
    self.original = original ?? next.interfaceOrientation
  }
  func update(_ mode: FullscreenMode, picture: CGSize, denied: @escaping () -> Void = {}) -> Bool {
    guard let scene else { return false }
    let bounds = scene.screen.bounds
    guard let wanted = mode.wanted(videoWidth: picture.width, videoHeight: picture.height,
      screenWidth: bounds.width, screenHeight: bounds.height) else {
      if last != nil { unlock() }
      return false
    }
    return request(wanted == .landscape ? .landscape : .portrait, denied: denied)
  }
  func restore(denied: @escaping () -> Void = {}) -> Bool {
    guard held, original != .unknown else { return false }
    return request(UIInterfaceOrientationMask(rawValue: 1 << original.rawValue), denied: denied)
  }
  private func request(_ mask: UIInterfaceOrientationMask, denied: @escaping () -> Void) -> Bool {
    guard let scene, last != mask else { return false }
    last = mask
    TheaterOrientation.byScene[ObjectIdentifier(scene)] = .init(token: token, mask: mask)
    invalidate(scene)
    let current = UIInterfaceOrientationMask(rawValue: 1 << scene.interfaceOrientation.rawValue)
    guard mask.intersection(current).isEmpty else { return false }
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] _ in
      guard let self, self.held, self.last == mask else { return }
      TheaterOrientation.byScene[ObjectIdentifier(scene)] = nil
      self.invalidate(scene)
      denied()
    }
    return true
  }
  private func invalidate(_ scene: UIWindowScene) {
    for window in scene.windows where window.isKeyWindow {
      var top = window.rootViewController
      while let next = top?.presentedViewController { top = next }
      top?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
  }
  private func unlock() {
    if let scene, held {
      TheaterOrientation.byScene[ObjectIdentifier(scene)] = nil
      invalidate(scene)
    }
    last = nil
  }
  func release(restore: Bool) {
    if restore { _ = self.restore() }
    unlock()
    scene = nil
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
  static func dismantleUIViewController(_ p: Probe, coordinator: ()) { p.orientation.release(restore: true) }
  final class Probe: UIViewController {
    let orientation = PlaybackOrientation()
    var mode = FullscreenMode.keep, size = CGSize.zero
    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      apply()
    }
    func apply() {
      guard let window = viewIfLoaded?.window else { return }
      orientation.attach(window)
      _ = orientation.update(mode, picture: size)
    }
  }
}

/// iPhone detail pages stay portrait. Turning the phone sideways opens fullscreen and turning it
/// back closes it again, as in the original client. Opening by rotation never animates the
/// cover, so the only motion is the system's own rotation.
struct RotateToFullscreen: ViewModifier {
  @Binding var theater: Bool
  @Binding var byRotation: Bool
  let covering: Bool
  let enabled: Bool
  func body(content: Content) -> some View {
    content
      .background(PortraitLock(active: enabled && !theater, handingOff: enabled && theater && !covering)
        .allowsHitTesting(false))
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
  let active: Bool, handingOff: Bool
  func makeUIViewController(context: Context) -> Probe { Probe() }
  func updateUIViewController(_ p: Probe, context: Context) {
    p.active = active
    p.handingOff = handingOff
    p.apply()
  }
  static func dismantleUIViewController(_ p: Probe, coordinator: ()) { p.release() }
  final class Probe: UIViewController {
    let token = UUID()
    var active = false, handingOff = false
    private weak var scene: UIWindowScene?
    private var visible = false
    override func loadView() {
      view = UIView()
      view.isUserInteractionEnabled = false
      // The fullscreen cover has a clear background, so the page under it never disappears and
      // this probe gets no viewDidAppear when it closes. Without this the page stayed unlocked
      // after the first fullscreen, so a later turn could rotate the whole page (and every
      // column under it) with the device instead of only opening fullscreen.
      NotificationCenter.default.addObserver(
        self, selector: #selector(ownerChanged), name: TheaterOrientation.ownerChanged, object: nil)
    }
    @objc private func ownerChanged() {
      DispatchQueue.main.async { [weak self] in self?.apply() }
    }
    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      visible = true
      apply()
    }
    override func viewDidDisappear(_ animated: Bool) {
      visible = false
      if !handingOff { release() }
      super.viewDidDisappear(animated)
    }
    func apply() {
      // Keep the existing portrait mask until the presented player has mounted and
      // requested its own geometry, even if UIKit hides this probe in between.
      if handingOff { return }
      guard visible, active, let w = viewIfLoaded?.window, let s = w.windowScene,
        w.traitCollection.userInterfaceIdiom == .phone, !WindowCanvas.isLarge(w.bounds.size)
      else {
        release()
        return
      }
      // The fullscreen owner drives the return rotation and keeps the mask until dismissal.
      if TheaterOrientation.byScene[ObjectIdentifier(s)] != nil { return }
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
