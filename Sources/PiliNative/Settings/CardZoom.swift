import SwiftUI
import UIKit

/// 一镜到底: a page opened from a card grows out of that card and shrinks back into it, instead of
/// sliding in from the side. The card's picture travels to the page's hero (the player of a video
/// page) inside a rounded shape that widens from the card to the screen, the page fading in on it
/// as soon as it is built; what lay underneath steps back and dims. On the way back the page
/// shrinks until what plays in its hero lies over the card's picture, and melts into the card. A
/// swipe from the edge carries the page along under the finger before it springs into the card
/// (or back out, if the swipe is called off). Everything moves on springs that run in the render
/// server, so a main thread busy building the page does not make them stutter.
///
/// Our own push / pop transition rather than the system zoom transition: SwiftUI has no way to
/// limit that one's drag-to-dismiss (UIKit's `interactiveDismissShouldBegin` has no SwiftUI
/// counterpart), and it needs iOS 18. Cards add no gesture either: a passive window recognizer
/// remembers where the last touch went down, and at push time the card marked under it is the
/// origin.
@MainActor enum CardZoom {
  fileprivate static let markers = NSHashTable<CardZoomMarkerView>.weakObjects()
  private static var touch: (point: CGPoint, time: TimeInterval)?
  private static let origins = NSMapTable<UIViewController, CardZoomOrigin>.weakToStrongObjects()
  private static let watched = NSHashTable<UIWindow>.weakObjects()
  /// Where pages had their hero, by page size (see `ZoomScene.landing`).
  fileprivate static var heroes: [String: CGRect] = [:]
  /// The page still on its way open. Its push is long over for UIKit (see
  /// `CardZoomTransition.open`), so another transition can begin under it at any time.
  fileprivate static var opening: CardZoomTransition?

  static func watch(_ window: UIWindow?) {
    guard let window, !watched.contains(window) else { return }
    watched.add(window)
    window.addGestureRecognizer(TouchWatch())
  }
  fileprivate static func touched(_ point: CGPoint?) {
    touch = point.map { ($0, ProcessInfo.processInfo.systemUptime) }
  }
  /// The card just tapped: the smallest marked card under the last touch, if that touch is recent
  /// enough to be the one that opened the page, with the picture marked inside it.
  private static func tappedOrigin() -> CardZoomOrigin? {
    guard let touch, ProcessInfo.processInfo.systemUptime - touch.time < 1.5 else { return nil }
    var card: (view: CardZoomMarkerView, frame: CGRect)?
    for marker in markers.allObjects where marker.role == .card {
      guard let frame = marker.windowFrame, frame.width >= 44, frame.height >= 30, frame.contains(touch.point)
      else { continue }
      if card.map({ frame.width * frame.height < $0.frame.width * $0.frame.height }) ?? true { card = (marker, frame) }
    }
    guard let card else { return nil }
    if card.view.system { return CardZoomOrigin(card: card.view, cover: nil) }
    var cover: (view: CardZoomMarkerView, area: CGFloat)?
    let bounds = card.frame.insetBy(dx: -1, dy: -1)
    for marker in markers.allObjects where marker.role == .cover && marker.window === card.view.window {
      guard let frame = marker.windowFrame, bounds.contains(frame) else { continue }
      let area = frame.width * frame.height
      if area > (cover?.area ?? 0) { cover = (marker, area) }
    }
    return CardZoomOrigin(card: card.view, cover: cover?.view)
  }
  static func pushAnimator(to page: UIViewController) -> UIViewControllerAnimatedTransitioning? {
    guard let origin = tappedOrigin() else { return nil }
    touch = nil
    // The system's zoom carries this page both ways (`CardZoomLink`): ours stands aside.
    if origin.system {
      systemPages.add(page)
      return nil
    }
    origins.setObject(origin, forKey: page)
    if UIAccessibility.isReduceMotionEnabled { return CardZoomFade(opening: true) }
    return CardZoomTransition(origin: origin, opening: true)
  }
  /// For a page that was opened from a card: the animator that shrinks it back into that card.
  static func popAnimator(from page: UIViewController) -> UIViewControllerAnimatedTransitioning? {
    guard let origin = origins.object(forKey: page) else { return nil }
    if UIAccessibility.isReduceMotionEnabled { return CardZoomFade(opening: false) }
    return CardZoomTransition(origin: origin, opening: false)
  }
  /// The same way back, carried by a finger that went down at `touch` (in the navigation
  /// controller's view): feed it with `drag` and `end`.
  static func interactivePop(from page: UIViewController, touch: CGPoint, rtl: Bool) -> CardZoomTransition? {
    guard !UIAccessibility.isReduceMotionEnabled, let origin = origins.object(forKey: page) else { return nil }
    let transition = CardZoomTransition(origin: origin, opening: false)
    transition.touch = touch
    transition.direction = rtl ? -1 : 1
    return transition
  }
  /// A page is still opening: a swipe back waits for it (a tap on Back turns it round at once).
  static var busy: Bool { opening != nil }
  private static let systemPages = NSHashTable<UIViewController>.weakObjects()
  /// Whether the system's zoom opened `page`: it also takes it back, by its own gestures, so no
  /// motion or swipe of ours may stand in for it.
  static func systemZoom(_ page: UIViewController) -> Bool {
    if systemPages.contains(page) { return true }
    // A page SwiftUI gave a zoom without a tap we saw (VoiceOver, a keyboard).
    if #available(iOS 18, *), page.preferredTransition != nil {
      systemPages.add(page)
      return true
    }
    return false
  }
  /// Another transition starts: a page still on its way open is put in place at once.
  static func settle() { opening?.settle() }
}

/// Marks a place the zoom reads at transition time: a card, the picture inside one, or the hero
/// of a page. A plain view rather than a tracked SwiftUI frame, so nothing runs while a feed
/// scrolls and the place is still right after the card has moved.
final class CardZoomMarkerView: UIView {
  enum Role { case card, cover, hero }
  var role = Role.card
  /// Corner radius of the shape the zoom starts from, where the marker knows it.
  var radius: CGFloat?
  /// A card the system's zoom opens its page from: only noted, so ours keeps out of it.
  var system = false
  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { CardZoom.markers.add(self) } else { CardZoom.markers.remove(self) }
  }
  fileprivate var windowFrame: CGRect? {
    guard let window else { return nil }
    return convert(bounds, to: window)
  }
}
private struct CardZoomMarker: UIViewRepresentable {
  let role: CardZoomMarkerView.Role
  var radius: CGFloat?
  var system = false
  func makeUIView(context: Context) -> CardZoomMarkerView {
    let view = CardZoomMarkerView()
    view.isUserInteractionEnabled = false
    updateUIView(view, context: context)
    return view
  }
  func updateUIView(_ view: CardZoomMarkerView, context: Context) {
    view.role = role
    view.radius = radius
    view.system = system
  }
}

/// The card a page was opened from, looked up again whenever the page goes back to it.
private final class CardZoomOrigin: NSObject {
  private weak var card: CardZoomMarkerView?
  private weak var cover: CardZoomMarkerView?
  let system: Bool
  @MainActor init(card: CardZoomMarkerView, cover: CardZoomMarkerView?) {
    self.card = card
    self.cover = cover
    system = card.system
  }
  /// Where the card is now, in `space`; nil once it is gone or mostly off screen.
  @MainActor func source(in space: UIView) -> ZoomSource? {
    guard let card, let window = card.window, window === space.window ?? space as? UIWindow else { return nil }
    let frame = card.convert(card.bounds, to: space)
    let seen = frame.intersection(space.bounds)
    guard frame.width >= 20, frame.height >= 20, !seen.isNull,
      seen.width * seen.height * 3 >= frame.width * frame.height else { return nil }
    guard let cover, cover.window === window else {
      return ZoomSource(frame: frame, cover: frame, radius: card.radius ?? 10)
    }
    let picture = cover.convert(cover.bounds, to: space)
    guard picture.width >= 20, picture.height >= 20 else {
      return ZoomSource(frame: frame, cover: frame, radius: card.radius ?? 10)
    }
    let radius = cover.radius ?? card.radius ?? 10
    // A picture as wide as its card takes the card along (its text fades into the page); a
    // thumbnail beside a row's text leaves the row where it is.
    if picture.width >= frame.width * 0.86 { return ZoomSource(frame: frame, cover: picture, radius: radius) }
    return ZoomSource(frame: picture, cover: picture, radius: radius)
  }
}
private struct ZoomSource {
  /// The shape the page grows out of, and the picture in it that becomes the page's hero.
  var frame: CGRect, cover: CGRect
  let radius: CGFloat
  /// The same card seen from another view of the same window.
  @MainActor func moved(from: UIView, to: UIView) -> ZoomSource {
    ZoomSource(frame: to.convert(frame, from: from), cover: to.convert(cover, from: from), radius: radius)
  }
}

/// Notes where each touch goes down and steps aside at once: it never recognizes, never delays or
/// cancels a touch, and never blocks another recognizer.
private final class TouchWatch: UIGestureRecognizer {
  init() {
    super.init(target: nil, action: nil)
    cancelsTouchesInView = false
    delaysTouchesBegan = false
    delaysTouchesEnded = false
  }
  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    if let t = touches.first, let window = view as? UIWindow {
      CardZoom.touched(Self.floating(t.view, in: window) ? nil : t.location(in: window))
    }
    state = .failed
  }
  /// A sheet, alert or menu over the cards is not a card: a pick there opens its page plainly.
  private static func floating(_ touched: UIView?, in window: UIWindow) -> Bool {
    var presented = window.rootViewController?.presentedViewController
    while let page = presented {
      if let host = page.viewIfLoaded, touched?.isDescendant(of: host) == true { return true }
      presented = page.presentedViewController
    }
    var view = touched
    while let current = view {
      // The class's own name only: a SwiftUI hosting view's generic arguments spell out the
      // whole view tree under it, so every touch would look like one on a menu or an alert.
      let name = String(describing: type(of: current)).prefix { $0 != "<" }
      if name.contains("Menu") || name.contains("Alert") { return true }
      view = current.superview
    }
    return false
  }
  override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
  override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
}

private struct CardZoomKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
  /// Whether links built with `LazyLink` here open their page out of the card (on by default).
  var cardZoom: Bool {
    get { self[CardZoomKey.self] }
    set { self[CardZoomKey.self] = newValue }
  }
  /// Which zoom those links use: set once per navigation stack from the setting, so a feed's
  /// cards do not each watch the defaults.
  var cardZoomStyle: CardZoomStyle {
    get { self[CardZoomStyleKey.self] }
    set { self[CardZoomStyleKey.self] = newValue }
  }
}
private struct CardZoomStyleKey: EnvironmentKey { static let defaultValue = CardZoomStyle.stored }

/// Which 一镜到底 a card opens its page with (页面动画与回弹 → 卡片展开).
enum CardZoomStyle: Int, CaseIterable {
  /// The system's zoom, from iOS 18 on (`navigationTransition(.zoom)`), with its own gestures
  /// back: a swipe from the edge, or a drag of the page anywhere.
  case system
  /// Ours (`CardZoomTransition`), and the only one before iOS 18.
  case custom
  static let key = "layout.cardZoomStyle"
  var title: String { self == .system ? "系统缩放" : "自定义" }
  static var stored: Self {
    (UserDefaults.standard.object(forKey: key) as? Int).flatMap(Self.init(rawValue:)) ?? .system
  }
}

/// `NavigationLink { destination } label: { label }` whose page grows out of the label and goes
/// back into it, built only when it is pushed (`DeferredPage`). `radius` is the label's corner
/// radius, for the system's zoom to start from.
struct CardZoomLink<Destination: View, Label: View>: View {
  let destination: () -> Destination
  let label: Label
  var radius: CGFloat?
  private let preferredStyle: CardZoomStyle?
  @Environment(\.cardZoom) private var enabled
  @Environment(\.cardZoomStyle) private var style
  @Environment(\.interfaceScaled) private var scaled
  @Namespace private var space
  init(radius: CGFloat? = nil, preferredStyle: CardZoomStyle? = nil,
       @ViewBuilder destination: @escaping () -> Destination, @ViewBuilder label: () -> Label) {
    self.destination = destination
    self.label = label()
    self.radius = radius
    self.preferredStyle = preferredStyle
  }
  var body: some View {
    if enabled && !scaled && (preferredStyle ?? style) == .system {
      if #available(iOS 18, *) {
        NavigationLink {
          DeferredPage(destination).navigationTransition(.zoom(sourceID: 0, in: space))
        } label: {
          label
            .matchedTransitionSource(id: 0, in: space) { source in
              source.clipShape(RoundedRectangle(cornerRadius: radius ?? NativeGlass.thumbRadius, style: .continuous))
            }
            .background { CardZoomMarker(role: .card, system: true).allowsHitTesting(false) }
        }
      } else {
        custom
      }
    } else {
      custom
    }
  }
  private var custom: some View {
    NavigationLink { DeferredPage(destination) } label: { label.modifier(CardZoomSource(radius: radius)) }
  }
}

/// Marks the view as a card a page can grow out of.
struct CardZoomSource: ViewModifier {
  var radius: CGFloat? = nil
  @Environment(\.cardZoom) private var enabled
  /// Scaled, the page no longer lines up with the screen the transition works in: such cards
  /// open plainly.
  @Environment(\.interfaceScaled) private var scaled
  @ViewBuilder func body(content: Content) -> some View {
    if enabled && !scaled {
      content.background { CardZoomMarker(role: .card, radius: radius).allowsHitTesting(false) }
    } else {
      content
    }
  }
}
extension View {
  /// The picture of a card: it is what travels to the opened page's hero. `radius` is the corner
  /// radius of the card when the picture spans it, or of the picture when it is a thumbnail.
  func cardZoomCover(radius: CGFloat? = nil) -> some View {
    background { CardZoomMarker(role: .cover, radius: radius).allowsHitTesting(false) }
  }
  /// Where a page receives the picture of the card that opened it (a player, a banner).
  func cardZoomHero() -> some View {
    background { CardZoomMarker(role: .hero).allowsHitTesting(false) }
  }
}

// MARK: - The transition

/// Everything the transition moves, at one moment.
private struct ZoomPose {
  /// The rounded shape the page shows through, in the view the transition is staged in.
  var clip: CGRect
  var radius: CGFloat
  /// Where the page's points go in that view (a uniform scale and an offset).
  var map: CGAffineTransform
  /// The shade over what lies underneath, and its scale.
  var dim: CGFloat
  var under: CGFloat
}

private struct ZoomSpring {
  let response: Double, damping: Double
  /// Out of the card: quick off the mark, settling without a bounce at the screen's edges.
  static let open = ZoomSpring(response: 0.44, damping: 0.86)
  /// Back into the card, and back to the full screen after a swipe that was called off.
  static let close = ZoomSpring(response: 0.38, damping: 0.9)
  static let back = ZoomSpring(response: 0.36, damping: 0.86)
  /// `velocity` is relative to the distance left to travel (1 covers it in a second).
  func timing(velocity: CGFloat = 0) -> UISpringTimingParameters {
    let stiffness = pow(2 * .pi / response, 2), friction = 4 * .pi * damping / response
    return UISpringTimingParameters(
      mass: 1, stiffness: stiffness, damping: friction, initialVelocity: CGVector(dx: velocity, dy: velocity))
  }
}

/// A soft shadow around the travelling page, as one stretchable picture: a layer shadow would be
/// blurred again on every frame of the resize.
@MainActor private enum ZoomShadow {
  static let reach: CGFloat = 40
  static let image: UIImage = {
    let corner: CGFloat = 22, side = 2 * (reach + corner) + 1
    let picture = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
      let c = context.cgContext
      let shape = UIBezierPath(
        roundedRect: CGRect(x: reach, y: reach, width: side - 2 * reach, height: side - 2 * reach),
        cornerRadius: corner).cgPath
      c.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: UIColor.black.withAlphaComponent(0.3).cgColor)
      c.setFillColor(UIColor.black.cgColor)
      c.addPath(shape)
      c.fillPath()
      // Only the shadow stays: the page's own corners are rounder or sharper than this shape's.
      c.setShadow(offset: .zero, blur: 0, color: nil)
      c.setBlendMode(.clear)
      c.addPath(shape)
      c.fillPath()
    }
    let cap = reach + corner
    return picture.resizableImage(
      withCapInsets: UIEdgeInsets(top: cap, left: cap, bottom: cap, right: cap), resizingMode: .stretch)
  }()
}

/// The views of one transition. The travelling page sits in `stage`, a view that keeps the size
/// the page has at rest (so the page's safe area never changes) and is masked by `clip`; `under`
/// is what shows around it.
@MainActor private final class ZoomScene {
  let page: UIView, under: UIView
  /// The masked view the page sits in, and the view `under`, the shade and the shadow lie in.
  let stage: UIView, ground: UIView
  let clip = UIView(), dim = UIView()
  let shadow = UIImageView(image: ZoomShadow.image)
  /// The page's frame at rest, and everything at rest with the page open.
  let home: CGRect
  let open: ZoomPose
  let source: ZoomSource?
  private var marked: CGRect?
  /// Opening: `under` is a picture made for the transition and the page stays where UIKit has
  /// it. Closing: `under` is the page coming back, and the stage is the scene's own.
  private let opening: Bool
  private let underTransform: CGAffineTransform
  private let size: CGSize
  /// The sheet the page fades in on while it opens.
  private let floor = UIView()

  /// The way back, in UIKit's transition container: `page` and, below it, `under` are in it.
  init(closing page: UIView, under: UIView, in container: UIView, source: ZoomSource?) {
    self.page = page
    self.under = under
    self.source = source
    opening = false
    ground = container
    stage = UIView(frame: container.bounds)
    underTransform = under.transform
    home = page.frame
    size = container.bounds.size
    container.insertSubview(dim, aboveSubview: under)
    container.insertSubview(shadow, aboveSubview: dim)
    container.insertSubview(stage, aboveSubview: shadow)
    stage.addSubview(page)
    marked = Self.hero(in: page, home: home)
    open = ZoomPose(clip: home, radius: Self.screenRadius(stage, home), map: .identity, dim: 0.18, under: 0.96)
    dress()
  }
  /// The way in, over a page already pushed. The page stays in the view UIKit keeps it in, which
  /// is masked itself: a pop that starts meanwhile takes the page's superview for its container,
  /// and that has to be UIKit's. `backdrop` goes under that view.
  init?(opening page: UIView, backdrop: UIView, source: ZoomSource?) {
    guard let stage = page.superview, let ground = stage.superview, stage.mask == nil else { return nil }
    self.page = page
    self.source = source
    self.stage = stage
    self.ground = ground
    under = backdrop
    opening = true
    underTransform = .identity
    home = page.frame
    size = stage.bounds.size
    ground.insertSubview(backdrop, belowSubview: stage)
    ground.insertSubview(dim, aboveSubview: backdrop)
    ground.insertSubview(shadow, aboveSubview: dim)
    floor.frame = stage.bounds
    floor.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    floor.isUserInteractionEnabled = false
    let own = page.backgroundColor.flatMap { $0.cgColor.alpha >= 1 ? $0 : nil }
    floor.backgroundColor = own ?? .systemBackground
    stage.insertSubview(floor, belowSubview: page)
    marked = Self.hero(in: page, home: home)
    // Remembered as a page first lays it out; later it may have grown (a portrait video's player).
    if let marked { CardZoom.heroes[Self.key(home.size)] = marked }
    open = ZoomPose(clip: home, radius: Self.screenRadius(stage, home), map: .identity, dim: 0.18, under: 0.96)
    dress()
  }
  private func dress() {
    dim.frame = ground.bounds
    dim.backgroundColor = .black
    dim.alpha = 0
    dim.isUserInteractionEnabled = false
    clip.backgroundColor = .black
    clip.layer.cornerCurve = .continuous
    stage.mask = clip
  }

  /// The page's marked hero, if most of it is on the page (a player folded away is not).
  private static func hero(in page: UIView, home: CGRect) -> CGRect? {
    var best: CGRect?
    for marker in CardZoom.markers.allObjects where marker.role == .hero && marker.isDescendant(of: page) {
      let frame = marker.convert(marker.bounds, to: page)
      let seen = frame.intersection(page.bounds)
      guard frame.width >= 60, frame.height >= 40, !seen.isNull,
        seen.width * seen.height >= frame.width * frame.height * 0.6 else { continue }
      if best.map({ frame.width * frame.height > $0.width * $0.height }) ?? true { best = frame }
    }
    return best?.offsetBy(dx: home.minX - page.bounds.minX, dy: home.minY - page.bounds.minY)
  }
  /// The radius of the display's own corners when the page fills it, so the shape never shows a
  /// sharper corner inside the glass than the screen has; 0 elsewhere.
  private static func screenRadius(_ space: UIView, _ home: CGRect) -> CGFloat {
    guard let window = space.window else { return 0 }
    let screen = window.screen, frame = space.convert(home, to: window)
    guard abs(frame.minX) < 0.5, abs(frame.minY) < 0.5, abs(frame.width - screen.bounds.width) < 0.5,
      abs(frame.height - screen.bounds.height) < 0.5 else { return 0 }
    let key = "_displayCornerRadius"
    guard screen.responds(to: NSSelectorFromString(key)), let value = screen.value(forKey: key) as? NSNumber
    else { return 0 }
    return CGFloat(value.doubleValue)
  }
  private static func key(_ size: CGSize) -> String { "\(Int(size.width))x\(Int(size.height))" }
  private static func count(_ view: UIView, upTo limit: Int) -> Int {
    var total = 1
    for sub in view.subviews where total < limit { total += count(sub, upTo: limit - total) }
    return total
  }

  /// Whether the page has drawn anything yet: SwiftUI builds a pushed page a moment after it has
  /// appeared, and its hosting view holds next to nothing until then.
  var hasContent: Bool {
    if marked != nil { return true }
    if let hero = Self.hero(in: page, home: home) {
      marked = hero
      if opening { CardZoom.heroes[Self.key(home.size)] = hero }
      return true
    }
    return Self.count(page, upTo: 9) >= 9
  }
  /// Where the card's picture lands on the page: the marked hero, where the last page of this
  /// size had its hero while this one is still being built, or else a strip of the picture's
  /// shape across the top of the page.
  func landing(for cover: CGRect) -> CGRect {
    marked ?? CardZoom.heroes[Self.key(home.size)] ?? CGRect(
      x: home.minX, y: home.minY, width: home.width,
      height: min(home.height, home.width * cover.height / max(1, cover.width)))
  }
  /// Where the card's picture comes to rest while the page opens: on the hero, and up to the
  /// page's top edge when only a strip (the status bar's) lies above it, so the sheet shows no
  /// bare band over the picture before the page has drawn that strip.
  func pictureLanding(for cover: CGRect) -> CGRect {
    var rect = landing(for: cover)
    let above = rect.minY - home.minY
    if above > 0, above <= home.height * 0.12, abs(rect.width - home.width) < 1 {
      rect.origin.y = home.minY
      rect.size.height += above
    }
    return rect
  }
  /// The page folded into the card. `filling`, it is scaled so that its hero covers the card's
  /// picture, centre on centre: what plays in the hero then lies exactly over that picture, and
  /// melts into it. Otherwise the hero takes the picture's width from its top edge, so the card
  /// spans the page it grows into.
  func cardPose(_ source: ZoomSource, filling: Bool) -> ZoomPose {
    let cover = source.cover, hero = filling ? landing(for: cover) : pictureLanding(for: cover)
    let wide = cover.width / max(1, hero.width), tall = cover.height / max(1, hero.height)
    let s = min(1.5, max(0.05, filling ? max(wide, tall) : wide))
    let map = filling
      ? CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: cover.midX - s * hero.midX, ty: cover.midY - s * hero.midY)
      : CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: cover.minX - s * hero.minX, ty: cover.minY - s * hero.minY)
    return ZoomPose(clip: source.frame, radius: source.radius, map: map, dim: 0, under: 1)
  }
  /// The page under a finger that went down at `touch` and has moved by `translation`: it shrinks
  /// around the finger and follows it, sideways at once and up and down once it has let go of
  /// the screen's edges.
  func dragPose(_ translation: CGPoint, touch: CGPoint, direction: CGFloat) -> (pose: ZoomPose, progress: CGFloat) {
    let along = max(0, translation.x * direction)
    let progress = min(1, along / max(1, home.width))
    let k = max(0.4, 1 - 0.85 * progress)
    let rise = min(1, progress / 0.12)
    let map = CGAffineTransform(
      a: k, b: 0, c: 0, d: k, tx: (1 - k) * touch.x + along * direction, ty: (1 - k) * touch.y + translation.y * rise)
    let ease = min(1, progress * 2)
    let pose = ZoomPose(
      clip: home.applying(map), radius: open.radius + (28 - open.radius) * ease, map: map,
      dim: open.dim * (1 - 0.5 * progress), under: open.under + (1 - open.under) * min(1, progress * 1.5))
    return (pose, progress)
  }
  /// Where the page goes when its card is gone: a little smaller, fading where it is.
  func receded(from pose: ZoomPose) -> ZoomPose {
    let k: CGFloat = 0.86
    let shrink = CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: (1 - k) * pose.clip.midX, ty: (1 - k) * pose.clip.midY)
    return ZoomPose(
      clip: pose.clip.applying(shrink), radius: max(pose.radius, 20), map: pose.map.concatenating(shrink),
      dim: 0, under: 1)
  }

  func apply(_ pose: ZoomPose) {
    clip.frame = pose.clip
    clip.layer.cornerRadius = min(pose.radius, min(pose.clip.width, pose.clip.height) / 2)
    shadow.frame = ground.convert(pose.clip, from: stage).insetBy(dx: -ZoomShadow.reach, dy: -ZoomShadow.reach)
    // A view's transform turns about its centre: restate the map that way.
    let m = pose.map
    page.transform = CGAffineTransform(
      a: m.a, b: 0, c: 0, d: m.d, tx: m.tx - (1 - m.a) * home.midX, ty: m.ty - (1 - m.d) * home.midY)
    dim.alpha = pose.dim
    under.transform = underTransform.scaledBy(x: pose.under, y: pose.under)
  }
  /// The pose on screen right now, mid-animation.
  var current: ZoomPose {
    let shape = clip.layer.presentation() ?? clip.layer
    let t = (page.layer.presentation() ?? page.layer).affineTransform()
    let below = (under.layer.presentation() ?? under.layer).affineTransform().a / max(0.01, underTransform.a)
    return ZoomPose(
      clip: shape.frame, radius: shape.cornerRadius,
      map: CGAffineTransform(a: t.a, b: 0, c: 0, d: t.d, tx: t.tx + (1 - t.a) * home.midX, ty: t.ty + (1 - t.d) * home.midY),
      dim: CGFloat((dim.layer.presentation() ?? dim.layer).opacity), under: below)
  }

  /// Takes the scene down. On the way back the page is handed to the container again: in front
  /// when it stays after all, at the back when it has gone into its card (UIKit removes it from
  /// there).
  func restore(front: Bool) {
    page.transform = .identity
    stage.mask = nil
    if opening {
      floor.removeFromSuperview()
      under.removeFromSuperview()
    } else {
      if front { ground.insertSubview(page, aboveSubview: stage) } else { ground.insertSubview(page, at: 0) }
      // The container may have been resized meanwhile (a turned device).
      page.frame = size == ground.bounds.size ? home : ground.bounds
      under.transform = underTransform
      stage.removeFromSuperview()
    }
    shadow.removeFromSuperview()
    dim.removeFromSuperview()
  }
}

/// Pictures of the card laid over the page while it opens: the whole card where it stood on the
/// page (it fades first, taking the title and counts with it), and its picture, which travels on
/// to the hero.
@MainActor private struct ZoomPictures {
  let card: UIView?
  let cover: UIView
  private let picture: UIView
  private let size: CGSize

  /// Taken from what `view` shows on screen at this moment: no drawing, and the card looks
  /// exactly as it was left. `source` is in `view`'s window.
  init?(of view: UIView, source: ZoomSource) {
    guard let window = view.window else { return nil }
    func shot(_ rect: CGRect) -> UIView? {
      let picture = view.resizableSnapshotView(
        from: view.convert(rect, from: window), afterScreenUpdates: false, withCapInsets: .zero)
      picture?.isUserInteractionEnabled = false
      return picture
    }
    guard let picture = shot(source.cover) else { return nil }
    self.picture = picture
    card = source.frame == source.cover ? nil : shot(source.frame)
    cover = UIView()
    cover.clipsToBounds = true
    cover.isUserInteractionEnabled = false
    cover.backgroundColor = .black
    cover.addSubview(picture)
    size = source.cover.size
  }
  /// Over the page as the card: `source` is in the stage's coordinates.
  func place(on stage: UIView, source: ZoomSource) {
    if let card {
      card.frame = source.frame
      stage.addSubview(card)
    }
    cover.frame = source.cover
    picture.frame = cover.bounds
    stage.addSubview(cover)
  }
  func remove() {
    card?.removeFromSuperview()
    cover.removeFromSuperview()
  }
  /// The picture at rest: whole and in proportion in the middle of `hero`, as a player shows a
  /// cover, so what the page then draws there lies over it line for line. The rest of `frame`
  /// (the hero and what lies above it) is black around it, as around a picture in a player.
  func land(in frame: CGRect, hero: CGRect) {
    let fit = min(hero.width / max(1, size.width), hero.height / max(1, size.height))
    let fitted = CGSize(width: size.width * fit, height: size.height * fit)
    cover.frame = frame
    picture.frame = CGRect(
      x: hero.midX - frame.minX - fitted.width / 2, y: hero.midY - frame.minY - fitted.height / 2,
      width: fitted.width, height: fitted.height)
  }
}

@MainActor final class CardZoomTransition: NSObject, UIViewControllerAnimatedTransitioning,
  UIViewControllerInteractiveTransitioning {
  private let origin: CardZoomOrigin
  private let opening: Bool
  fileprivate var touch = CGPoint.zero
  fileprivate var direction: CGFloat = 1
  private var scene: ZoomScene?
  private var context: UIViewControllerContextTransitioning?
  private var motion: UIViewPropertyAnimator?
  /// Where the finger has the page, how far it has moved, and a lift that came before UIKit had
  /// started the transition.
  private var held: ZoomPose?
  private var dragged = CGPoint.zero
  private var lifted: (finish: Bool, velocity: CGPoint)?
  private var settling = false
  /// The once-a-frame check of an opening page (see `uncover`), and the navigation bar kept out
  /// of sight meanwhile.
  private var ticker: CADisplayLink?
  private var check: (() -> Bool)?
  private weak var bar: UINavigationBar?
  private var pictures: ZoomPictures?

  fileprivate init(origin: CardZoomOrigin, opening: Bool) {
    self.origin = origin
    self.opening = opening
  }
  func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
    opening ? 0 : 0.4
  }
  func animateTransition(using ctx: UIViewControllerContextTransitioning) {
    if opening {
      open(ctx)
    } else if let start = stageClosing(ctx), let scene {
      close(scene, from: start, velocity: .zero, delay: 0.2)
    } else {
      ctx.completeTransition(false)
    }
  }
  func startInteractiveTransition(_ ctx: UIViewControllerContextTransitioning) {
    guard stageClosing(ctx) != nil else {
      ctx.cancelInteractiveTransition()
      ctx.completeTransition(false)
      return
    }
    drag(dragged)
    if let lifted {
      self.lifted = nil
      end(finish: lifted.finish, velocity: lifted.velocity)
    }
  }

  // MARK: Opening

  /// The push itself is over at once: the page is put in place and the transition completed
  /// before anything moves, and the zoom then plays over the finished page, with a picture of the
  /// screen as it was underneath. While a transition runs UIKit takes no touch and starts no
  /// other, so a tap on Back had to wait the zoom out; this way it turns the page round where it
  /// stands. And SwiftUI, which builds a pushed page some time into the push (a fifth to a third
  /// of a second on the phone, now and then only once the transition had ended), is never kept
  /// waiting by ours.
  private func open(_ ctx: UIViewControllerContextTransitioning) {
    guard let from = ctx.view(forKey: .from), let to = ctx.view(forKey: .to),
      let destination = ctx.viewController(forKey: .to) else { ctx.completeTransition(false); return }
    let container = ctx.containerView, window = container.window
    let area = window.map { container.convert(container.bounds, to: $0) }
    // The screen as it is, a page still opening included, then that page in place under it.
    let backdrop = area.flatMap {
      window?.resizableSnapshotView(from: $0, afterScreenUpdates: false, withCapInsets: .zero)
    }
    CardZoom.settle()
    let source = window.flatMap { origin.source(in: $0) }
    let pictures = source.flatMap { ZoomPictures(of: from, source: $0) }
    let final = ctx.finalFrame(for: destination)
    to.frame = final.isEmpty ? container.bounds : final
    container.addSubview(to)
    bar = destination.navigationController?.navigationBar
    ctx.completeTransition(true)
    guard let window, let area, let backdrop, let wrapper = to.superview, let ground = wrapper.superview,
      to.window === window else { return }
    backdrop.isUserInteractionEnabled = false
    backdrop.frame = ground.convert(area, from: window)
    guard let scene = ZoomScene(opening: to, backdrop: backdrop, source: source?.moved(from: window, to: wrapper))
    else { return }
    self.scene = scene
    self.pictures = pictures
    CardZoom.opening = self
    // A page that has not said yet whether it wants a navigation bar shows a bare back button
    // over the card: the bar stays out of sight until the page is built and nearly open.
    // Masked rather than faded, which would change the page's safe area.
    if let bar, bar.layer.mask == nil { bar.layer.mask = CALayer() } else { bar = nil }
    let move = UIViewPropertyAnimator(duration: 0, timingParameters: ZoomSpring.open.timing())
    if let source = scene.source {
      let card = scene.cardPose(source, filling: false)
      let hero = scene.landing(for: source.cover), frame = scene.pictureLanding(for: source.cover)
      // The page is blank until SwiftUI has built it, usually most of the way through: until
      // then the shape is a plain sheet of the page's own background under the card's picture,
      // and the page fades in on it rather than popping up.
      to.alpha = 0
      pictures?.place(on: scene.stage, source: source)
      scene.apply(card)
      scene.shadow.alpha = 0
      let rest = source.frame.applying(card.map.inverted())
      move.addAnimations {
        scene.apply(scene.open)
        pictures?.card?.frame = rest
        pictures?.land(in: frame, hero: hero)
      }
      // The card's title and counts go at once, before they have grown blurred.
      Self.fade(after: 0, over: 0.16) {
        scene.shadow.alpha = 1
        pictures?.card?.alpha = 0
      }
      uncover(pictures, over: scene, cover: source.cover, assumed: hero)
    } else {
      // The card went away between the tap and the push: the page just comes forward.
      scene.apply(scene.receded(from: scene.open))
      scene.stage.alpha = 0
      scene.shadow.alpha = 0
      move.addAnimations { scene.apply(scene.open) }
      Self.fade(after: 0, over: 0.2) { scene.stage.alpha = 1 }
      uncover(nil, over: scene, cover: .zero, assumed: .zero)
    }
    move.addCompletion { [self] _ in opened(scene) }
    move.startAnimation()
    motion = move
  }
  /// Waits, a frame at a time, for the page to have drawn something of its own, then lets it
  /// show: the page fades in on the sheet, and the card's picture gives way to the hero, though
  /// not before it has ridden most of the way there.
  private func uncover(_ pictures: ZoomPictures?, over scene: ZoomScene, cover: CGRect, assumed: CGRect) {
    let clock = scene.stage.layer
    let began = CACurrentMediaTime(), start = clock.convertTime(began, from: nil)
    var built = false
    each { [weak self] in
      guard let self, self.scene === scene else { return true }
      let elapsed = clock.convertTime(CACurrentMediaTime(), from: nil) - start
      if !built, scene.hasContent || CACurrentMediaTime() - began > 0.4 {
        built = true
        Self.fade(after: 0, over: 0.18) { scene.page.alpha = 1 }
        if let pictures {
          let hero = scene.landing(for: cover)
          if abs(hero.minX - assumed.minX) + abs(hero.minY - assumed.minY) + abs(hero.width - assumed.width)
            + abs(hero.height - assumed.height) > 1 {
            // The hero is not where the last page had it: the picture bends its way there.
            let frame = scene.pictureLanding(for: cover)
            let turn = UIViewPropertyAnimator(duration: 0, timingParameters: ZoomSpring.open.timing())
            turn.addAnimations { pictures.land(in: frame, hero: hero) }
            turn.startAnimation()
          }
          Self.fade(after: max(0, 0.2 - elapsed), over: 0.24) { pictures.cover.alpha = 0 }
        }
      }
      guard built, elapsed >= 0.3 else { return false }
      self.showBar(animated: true)
      return true
    }
  }
  private func showBar(animated: Bool) {
    guard let bar else { return }
    self.bar = nil
    guard animated, bar.window != nil, !bar.isHidden else { bar.layer.mask = nil; return }
    UIView.transition(with: bar, duration: 0.2, options: [.transitionCrossDissolve]) { bar.layer.mask = nil }
  }
  /// Runs `check` now and then once a frame until it returns true.
  private func each(_ check: @escaping () -> Bool) {
    guard !check() else { return }
    self.check = check
    let link = CADisplayLink(target: self, selector: #selector(tick))
    link.add(to: .main, forMode: .common)
    ticker = link
  }
  @objc private func tick() {
    guard let check, !check() else {
      ticker?.invalidate()
      ticker = nil
      check = nil
      return
    }
  }
  /// The page is open (or is taken over where it stands): everything staged for it goes.
  private func opened(_ scene: ZoomScene) {
    guard self.scene === scene else { return }
    self.scene = nil
    if let motion, motion.state == .active { motion.stopAnimation(true) }
    motion = nil
    ticker?.invalidate()
    ticker = nil
    check = nil
    showBar(animated: false)
    pictures?.remove()
    pictures = nil
    scene.page.alpha = 1
    scene.stage.alpha = 1
    scene.restore(front: true)
    if CardZoom.opening === self { CardZoom.opening = nil }
  }
  fileprivate func settle() {
    if let scene { opened(scene) }
  }
  /// Another transition takes `page` while it is still opening: where it stands, if it is ours.
  private func handOver(_ page: UIView) -> ZoomPose? {
    guard let scene else { return nil }
    let pose = scene.page === page ? scene.current : nil
    opened(scene)
    return pose
  }

  // MARK: Closing

  /// Stages the way back and returns where the page starts from: open, or wherever it had got
  /// to if it was still opening.
  private func stageClosing(_ ctx: UIViewControllerContextTransitioning) -> ZoomPose? {
    guard let from = ctx.view(forKey: .from), let to = ctx.view(forKey: .to),
      let destination = ctx.viewController(forKey: .to) else { return nil }
    let container = ctx.containerView
    let resumed = CardZoom.opening?.handOver(from)
    let final = ctx.finalFrame(for: destination)
    to.frame = final.isEmpty ? container.bounds : final
    if from.superview !== container { container.addSubview(from) }
    container.insertSubview(to, belowSubview: from)
    // The page coming back lays out now, which puts the card to return to in place before it
    // is looked up.
    to.layoutIfNeeded()
    let scene = ZoomScene(closing: from, under: to, in: container, source: origin.source(in: container))
    self.scene = scene
    context = ctx
    return resumed ?? scene.open
  }
  /// The finger has moved by `translation` since it went down.
  func drag(_ translation: CGPoint) {
    dragged = translation
    guard let scene, !settling else { return }
    let next = scene.dragPose(translation, touch: touch, direction: direction)
    scene.apply(next.pose)
    held = next.pose
    context?.updateInteractiveTransition(next.progress)
  }
  /// The finger has lifted, moving at `velocity`: on into the card, or back out to the screen.
  func end(finish through: Bool, velocity: CGPoint) {
    guard let scene else { lifted = (through, velocity); return }
    guard !settling else { return }
    settling = true
    let start = held ?? scene.open
    if through {
      context?.finishInteractiveTransition()
      close(scene, from: start, velocity: velocity, delay: 0.14)
    } else {
      context?.cancelInteractiveTransition()
      let move = UIViewPropertyAnimator(
        duration: 0, timingParameters: ZoomSpring.back.timing(velocity: Self.pace(velocity, from: start, to: scene.open)))
      move.addAnimations { scene.apply(scene.open) }
      move.addCompletion { [self] _ in closed(scene, completed: false) }
      move.startAnimation()
      motion = move
    }
  }
  /// Into the card from `start`, then the page melts into the card it has all but reached. The
  /// transition ends with that, not with the tail of the spring.
  private func close(_ scene: ZoomScene, from start: ZoomPose, velocity: CGPoint, delay: TimeInterval) {
    scene.apply(start)
    let target = scene.source.map { scene.cardPose($0, filling: true) } ?? scene.receded(from: start)
    let move = UIViewPropertyAnimator(
      duration: 0, timingParameters: ZoomSpring.close.timing(velocity: Self.pace(velocity, from: start, to: target)))
    move.addAnimations { scene.apply(target) }
    move.startAnimation()
    motion = move
    Self.fade(after: scene.source == nil ? 0 : delay, over: 0.17) {
      scene.stage.alpha = 0
      scene.shadow.alpha = 0
    } then: { [self] in
      if move.state == .active { move.stopAnimation(true) }
      closed(scene, completed: true)
    }
  }
  private func closed(_ scene: ZoomScene, completed: Bool) {
    guard self.scene === scene, let ctx = context else { return }
    self.scene = nil
    context = nil
    motion = nil
    scene.restore(front: !completed)
    if !completed { ctx.view(forKey: .to)?.removeFromSuperview() }
    ctx.completeTransition(completed)
  }

  /// A fade that starts `delay` into the transition, timed on the animation's own clock like the
  /// springs it runs beside (a plain delay counts wall time, which a slowed debug launch stretches
  /// the springs away from).
  private static func fade(
    after delay: TimeInterval, over duration: TimeInterval, _ change: @escaping () -> Void,
    then completion: (() -> Void)? = nil
  ) {
    let total = delay + duration
    let linear = UIView.KeyframeAnimationOptions(rawValue: UIView.AnimationOptions.curveLinear.rawValue)
    UIView.animateKeyframes(withDuration: total, delay: 0, options: [linear, .calculationModeLinear]) {
      UIView.addKeyframe(withRelativeStartTime: delay / total, relativeDuration: duration / total, animations: change)
    } completion: { _ in completion?() }
  }
  /// The finger's speed along the way from `start` to `target`, relative to that distance.
  private static func pace(_ velocity: CGPoint, from start: ZoomPose, to target: ZoomPose) -> CGFloat {
    let dx = target.clip.midX - start.clip.midX, dy = target.clip.midY - start.clip.midY
    let distance = dx * dx + dy * dy
    guard distance > 16 else { return 0 }
    return min(14, max(-4, (velocity.x * dx + velocity.y * dy) / distance))
  }
}

/// Reduce Motion: a page opened from a card fades in over it and fades back out.
final class CardZoomFade: NSObject, UIViewControllerAnimatedTransitioning {
  let opening: Bool
  init(opening: Bool) { self.opening = opening }
  func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval { 0.25 }
  func animateTransition(using ctx: UIViewControllerContextTransitioning) {
    guard let from = ctx.view(forKey: .from), let to = ctx.view(forKey: .to),
      let destination = ctx.viewController(forKey: .to) else { ctx.completeTransition(false); return }
    let container = ctx.containerView, final = ctx.finalFrame(for: destination)
    to.frame = final.isEmpty ? container.bounds : final
    if opening { container.addSubview(to) } else { container.insertSubview(to, belowSubview: from) }
    let front = opening ? to : from, alpha = front.alpha
    if opening { front.alpha = 0 }
    UIView.animate(withDuration: transitionDuration(using: ctx), delay: 0, options: [.curveEaseInOut]) {
      front.alpha = self.opening ? alpha : 0
    } completion: { _ in
      front.alpha = alpha
      if ctx.transitionWasCancelled { to.removeFromSuperview() }
      ctx.completeTransition(!ctx.transitionWasCancelled)
    }
  }
}
