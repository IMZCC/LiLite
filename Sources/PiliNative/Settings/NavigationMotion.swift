import SwiftUI
import UIKit

private struct IncomingTabLinkKey: EnvironmentKey {
  static let defaultValue: Binding<IncomingRoute?>? = nil
}
extension EnvironmentValues {
  var incomingTabLink: Binding<IncomingRoute?>? {
    get { self[IncomingTabLinkKey.self] }
    set { self[IncomingTabLinkKey.self] = newValue }
  }
}

struct PiliNavigationStack<Content: View>: View {
  private let content: Content
  @Environment(\.incomingTabLink) private var incoming
  @AppStorage(CardZoomStyle.key) private var zoomStyle = CardZoomStyle.system.rawValue
  @State private var tabBarHidden = false
  init(@ViewBuilder content: () -> Content) { self.content = content() }
  var body: some View {
    SwiftUI.NavigationStack {
      content
        .navigationDestination(item: incoming ?? .constant(nil)) { request in
          LinkDestination(item: request.link)
        }
        .background(MotionProbe().frame(width: 0, height: 0))
        .background(NavigationTabBarProbe { hidden in
          if tabBarHidden != hidden { tabBarHidden = hidden }
        }.frame(width: 0, height: 0))
    }.toolbar(tabBarHidden || incoming?.wrappedValue != nil ? .hidden : .visible, for: .tabBar)
      .environment(\.cardZoomStyle, CardZoomStyle(rawValue: zoomStyle) ?? .system)
      .piliTabBarBackground()
      // One set of card-menu sheets and dialogs for every page of this stack.
      .modifier(ArchiveCoverPresenter())
      // Only this stack consumes the tab's route. Pushed pages and their sheets can host stacks of their own.
      .environment(\.incomingTabLink, nil)
  }
}

struct MotionProbe: UIViewControllerRepresentable {
  @AppStorage(PageMotion.key) private var setting = PageMotion.native.rawValue
  func makeUIViewController(context: Context) -> Probe { Probe() }
  func updateUIViewController(_ c: Probe, context: Context) { _ = setting; c.attach() }
  final class Probe: UIViewController {
    override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
    override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); attach() }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); attach() }
    func attach() {
      guard isViewLoaded, view.window != nil, let nav = navigationController else { return }
      MotionHook.install(nav)
      CardZoom.watch(view.window)
      if let debugAnimationSpeed { view.window?.layer.speed = debugAnimationSpeed }
    }
  }
}
/// Debug launches only (`PILI_ANIMATION_SPEED=0.2` in the launch environment): UIKit and Core
/// Animation run that much slower in the window, so device screenshots catch transitions frame
/// by frame.
private let debugAnimationSpeed = ProcessInfo.processInfo.environment["PILI_ANIMATION_SPEED"].flatMap(Float.init)
/// Our page motions (一镜到底 out of a card, and the custom motion settings).
///
/// Not a proxy in front of SwiftUI's navigation delegate: once the delegate is anything but its
/// own coordinator, SwiftUI (iOS 26 on) pushes every page without animation. Instead the
/// coordinator's class answers `animationControllerFor` through `MotionRouting` first, and falls
/// back to its own answer (or the system's) when we have none.
@MainActor private enum MotionHook {
  private static var hooked = Set<ObjectIdentifier>()
  private static let refreshed = NSHashTable<UINavigationController>.weakObjects()
  private static var scrollKey: UInt8 = 0
  static func install(_ nav: UINavigationController) {
    guard let delegate = nav.delegate, !(delegate is LeadingPopTransition) else { return }
    if objc_getAssociatedObject(nav, &scrollKey) == nil {
      objc_setAssociatedObject(nav, &scrollKey, ScrollRebound(host: nav.view), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    guard let type = object_getClass(delegate) else { return }
    if hooked.insert(ObjectIdentifier(type)).inserted { hook(type) }
    // UIKit may have noted what the delegate answers when it was set: set it again once.
    if !refreshed.contains(nav) {
      refreshed.add(nav)
      nav.delegate = nil
      nav.delegate = delegate
    }
  }
  private typealias Answer = @convention(c) (AnyObject, Selector, UINavigationController,
    UINavigationController.Operation, UIViewController, UIViewController) -> UIViewControllerAnimatedTransitioning?
  private static func hook(_ type: AnyClass) {
    let selector = #selector(UINavigationControllerDelegate.navigationController(_:animationControllerFor:from:to:))
    let existing = class_getInstanceMethod(type, selector)
    let previous = existing.map { unsafeBitCast(method_getImplementation($0), to: Answer.self) }
    let encoding = existing.flatMap { method_getTypeEncoding($0) }.map { String(cString: $0) } ?? "@@:@q@@"
    let block: @convention(block) (AnyObject, UINavigationController, UINavigationController.Operation,
      UIViewController, UIViewController) -> UIViewControllerAnimatedTransitioning? = { me, nav, operation, from, to in
      // UIKit asks on the main thread.
      nonisolated(unsafe) var ours: UIViewControllerAnimatedTransitioning?
      MainActor.assumeIsolated { ours = MotionRouting.animator(nav, operation, from, to) }
      return ours ?? previous?(me, selector, nav, operation, from, to)
    }
    class_replaceMethod(type, selector, imp_implementationWithBlock(block), encoding)
  }
}
@MainActor enum MotionRouting {
  static func animator(_ nav: UINavigationController, _ operation: UINavigationController.Operation,
    _ fromVC: UIViewController, _ toVC: UIViewController) -> UIViewControllerAnimatedTransitioning? {
    if operation == .pop { ListRowSelection.clear(returningTo: toVC, in: nav) }
    let mode = PageMotion.current
    let state = nav.interactivePopGestureRecognizer?.state
    let contentState = nav.piliContentPopGesture?.state
    let interactive = operation == .pop && (state == .began || state == .changed || contentState == .began
      || contentState == .changed || nav.transitionCoordinator?.isInteractive == true)
    // 一镜到底: a page opened from a card grows out of it, and a tap on Back shrinks it back in.
    // The system's own edge swipe keeps its finger-following slide.
    if operation == .push, let zoom = CardZoom.pushAnimator(to: toVC) { return zoom }
    // The system's zoom (卡片展开 → 系统缩放) carries its pages both ways.
    if CardZoom.systemZoom(operation == .push ? toVC : fromVC) { return nil }
    if operation == .pop, !interactive, let zoom = CardZoom.popAnimator(from: fromVC) { return zoom }
    // Any other motion starts from pages at rest.
    CardZoom.settle()
    if !mode.custom(reduced: UIAccessibility.isReduceMotionEnabled, interactivePop: interactive) { return nil }
    return MotionAnimator(mode: mode, opening: operation != .pop)
  }
}
/// UIKit's `clearsSelectionOnViewWillAppear` for SwiftUI lists: when a page comes back into view,
/// the row that opened the page above it is deselected along with the transition, and selected
/// again if the swipe back is called off. SwiftUI leaves that row selected after some pops in
/// deeper stacks (我的 → 追番追剧 → a season), which shows as a row missing its separators.
@MainActor enum ListRowSelection {
  /// Asked for the animator before the transition starts: deselect alongside it once it runs.
  static func clear(returningTo page: UIViewController, in nav: UINavigationController) {
    DispatchQueue.main.async { [weak page, weak nav] in
      guard let page, let nav else { return }
      clear(in: page, along: nav.transitionCoordinator)
    }
  }
  private struct Marked {
    var selected: [(list: UICollectionView, rows: [IndexPath])] = []
    // A tap that opened the page can also leave its row highlighted (the touch never ended in the
    // list), which hides the same separators.
    var pressed: [UICollectionViewCell] = []
    var isEmpty: Bool { selected.isEmpty && pressed.isEmpty }
  }
  private static func scan(_ root: UIView) -> Marked {
    var marked = Marked()
    func visit(_ view: UIView) {
      if let list = view as? UICollectionView {
        if let rows = list.indexPathsForSelectedItems, !rows.isEmpty { marked.selected.append((list, rows)) }
        marked.pressed += list.visibleCells.filter { $0.isHighlighted || $0.isSelected }
      }
      for sub in view.subviews { visit(sub) }
    }
    visit(root)
    return marked
  }
  private static func unmark(_ marked: Marked, animated: Bool) {
    for (list, rows) in marked.selected { for row in rows { list.deselectItem(at: row, animated: animated) } }
    for cell in marked.pressed {
      cell.isHighlighted = false
      cell.isSelected = false
    }
  }
  static func clear(in page: UIViewController, along coordinator: UIViewControllerTransitionCoordinator?) {
    guard let root = page.viewIfLoaded else { return }
    let marked = scan(root)
    guard let coordinator else { unmark(marked, animated: false); return }
    coordinator.animate(alongsideTransition: { _ in unmark(marked, animated: true) }, completion: { context in
      if context.isCancelled {
        for (list, rows) in marked.selected { for row in rows { list.selectItem(at: row, animated: false, scrollPosition: []) } }
        return
      }
      // SwiftUI can mark the row again as the page settles: sweep once the transition is over.
      unmark(scan(root), animated: false)
    })
  }
}
final class MotionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
  let mode: PageMotion, opening: Bool
  init(mode: PageMotion, opening: Bool) { self.mode = mode; self.opening = opening }
  func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval { mode == .none ? 0 : 0.3 }
  func animateTransition(using ctx: UIViewControllerContextTransitioning) {
    guard let old = ctx.view(forKey: .from), let new = ctx.view(forKey: .to), let dest = ctx.viewController(forKey: .to) else {
      ctx.completeTransition(false); return
    }
    let parent = ctx.containerView, frame = ctx.finalFrame(for: dest)
    new.frame = frame.isEmpty ? parent.bounds : frame
    if opening { parent.addSubview(new) } else { parent.insertSubview(new, belowSubview: old) }
    let front = opening ? new : old, back = opening ? old : new
    let w = parent.bounds.width, h = parent.bounds.height
    let duration = transitionDuration(using: ctx)
    let f0 = front.transform, b0 = back.transform, a0 = front.alpha, bAlpha = back.alpha
    let previousMask = front.layer.mask
    var f = CGAffineTransform.identity, b = CGAffineTransform.identity, alpha: CGFloat = 1
    switch mode {
    case .fromRight, .rightFade: f = .init(translationX: w, y: 0); b = .init(translationX: -w * (mode == .rightFade ? 1 : 0.22), y: 0)
    case .fromLeft, .leftFade: f = .init(translationX: -w, y: 0); b = .init(translationX: w * (mode == .leftFade ? 1 : 0.22), y: 0)
    case .fromTop: f = .init(translationX: 0, y: -h)
    case .fromBottom: f = .init(translationX: 0, y: h)
    case .fade: f = .init(translationX: 0, y: min(32, h * 0.08)); alpha = 0
    case .fadeIn: alpha = 0
    case .zoom, .topLevel: f = .init(scaleX: 0.86, y: 0.86); b = .init(scaleX: 1.04, y: 1.04); alpha = 0
    case .revealSize: f = .init(scaleX: 1, y: 0.01); alpha = 0
    case .sharedAxis: f = .init(translationX: w * 0.12, y: 0); b = .init(translationX: -w * 0.12, y: 0); alpha = 0
    default: break
    }
    if mode == .rightFade || mode == .leftFade { alpha = 0 }
    if mode == .circle {
      let bounds = front.bounds, center = CGPoint(x: bounds.midX, y: bounds.midY)
      let radius = hypot(bounds.width, bounds.height) / 2 + 1
      func circle(_ r: CGFloat) -> CGPath { UIBezierPath(ovalIn: .init(x: center.x-r, y: center.y-r, width: 2*r, height: 2*r)).cgPath }
      let mask = CAShapeLayer()
      mask.frame = bounds; mask.path = circle(opening ? radius : 0.01); front.layer.mask = mask
      let anim = CABasicAnimation(keyPath: "path")
      anim.fromValue = circle(opening ? 0.01 : radius); anim.toValue = mask.path; anim.duration = duration
      anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      mask.add(anim, forKey: "PiliCircle")
    }
    func apply(frontHidden: Bool) {
      front.transform = frontHidden ? f.concatenating(f0) : f0
      front.alpha = frontHidden ? alpha * a0 : a0
      back.transform = frontHidden ? b0 : b.concatenating(b0)
    }
    apply(frontHidden: opening)
    let finish: (Bool) -> Void = { _ in
      front.transform = f0; back.transform = b0; front.alpha = a0; back.alpha = bAlpha
      if self.mode == .circle { front.layer.mask = previousMask }
      if ctx.transitionWasCancelled { new.removeFromSuperview() }
      ctx.completeTransition(!ctx.transitionWasCancelled)
    }
    if duration == 0 { finish(true) }
    else { UIView.animate(withDuration: duration, delay: 0, options: [ctx.isInteractive ? .curveLinear : .curveEaseInOut, .beginFromCurrentState], animations: { apply(frontHidden: !self.opening) }, completion: finish) }
  }
}
