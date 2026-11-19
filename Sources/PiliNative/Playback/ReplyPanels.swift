import SwiftUI

/// A comment thread opened inside the video detail. As in the original client it slides up as a
/// panel over the tabs and lists under the player (never over the video), titled "评论详情" or
/// "对话列表", and closes with its button or a swipe to the right.
struct ReplyPanelItem: Identifiable {
  let id: UUID
  let title: String
  let content: AnyView
  init(title: String, content: AnyView) {
    id = UUID()
    self.title = title
    self.content = content
  }
}

/// Opens a panel in the video detail that hosts it; returns false when no live host is on screen
/// (the comments then open as a page, as everywhere else).
struct ReplyPanelPresenter {
  let push: @MainActor (_ title: String, _ content: AnyView) -> Bool
}
private struct ReplyPanelPresenterKey: EnvironmentKey {
  static let defaultValue: ReplyPanelPresenter? = nil
}
extension EnvironmentValues {
  var replyPanelPresenter: ReplyPanelPresenter? {
    get { self[ReplyPanelPresenterKey.self] }
    set { self[ReplyPanelPresenterKey.self] = newValue }
  }
}

struct ReplyPanelStack: View {
  @Binding var items: [ReplyPanelItem]
  var body: some View {
    ZStack {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        ReplyPanelChrome(title: item.title) {
          close(item.id)
        } content: {
          item.content
        }
        .zIndex(Double(index))
        .transition(.move(edge: .bottom))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .allowsHitTesting(!items.isEmpty)
    .animation(.smooth(duration: 0.3), value: items.map(\.id))
  }
  private func close(_ id: UUID) {
    items.removeAll { $0.id == id }
  }
}

private struct ReplyPanelChrome<Content: View>: View {
  let title: String
  let close: () -> Void
  @ViewBuilder let content: () -> Content
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(title).font(.subheadline)
        Spacer()
        Button {
          TouchFeedback.light()
          close()
        } label: {
          Image(systemName: "xmark").font(.system(size: 15, weight: .medium))
            .foregroundStyle(.secondary).frame(width: 44, height: 44).contentShape(.rect)
        }
        .buttonStyle(.plain).accessibilityLabel("关闭")
      }
      .padding(.leading, 14).padding(.trailing, 2).frame(height: ReplyPanelDrag.header)
      Divider().opacity(0.5)
      content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color(uiColor: .systemBackground))
    .modifier(ReplyPanelDrag(close: close))
  }
}

/// Closes a panel by dragging it, following the finger: right to slide it away like the
/// original's page, or down (from the title bar, or from the list once it is at its top) as in
/// the official app. The offsets live in this modifier, so a drag never re-renders the thread.
private struct ReplyPanelDrag: ViewModifier {
  static let header: CGFloat = 45
  /// Measured outside the offset, so a drag's translation is the finger's own movement.
  private static let space = "pili.replyPanel"
  let close: () -> Void
  @State private var drag: CGFloat = 0
  @State private var pull: CGFloat = 0
  @State private var axis: Axis?
  @State private var fromHeader = false
  @State private var height: CGFloat = 600
  @GestureState private var touching = false
  func body(content: Content) -> some View {
    content
      .background {
        ReplyPanelPullMarker { value in
          guard axis != .horizontal, !fromHeader else { return false }
          axis = value > 0 ? .vertical : nil
          pull = value
          return true
        } released: { value, velocity in
          guard axis != .horizontal, !fromHeader else { return }
          axis = nil
          settle(value, velocity: velocity)
        }
      }
      .offset(x: drag, y: pull)
      .simultaneousGesture(
        DragGesture(minimumDistance: 12, coordinateSpace: .named(Self.space))
          .updating($touching) { _, state, _ in state = true }
          .onChanged { g in
            let w = g.translation.width, h = g.translation.height
            if axis == nil {
              if w > 0, abs(w) > abs(h) * 1.4 {
                axis = .horizontal
              } else if h > 0, abs(h) > abs(w), g.startLocation.y <= Self.header {
                axis = .vertical
                fromHeader = true
              } else {
                return
              }
            }
            if axis == .horizontal { drag = max(0, w) } else if fromHeader { pull = max(0, h) }
          }
          .onEnded { g in
            if axis == .horizontal {
              axis = nil
              let far = drag > 110 || (drag > 30 && g.predictedEndTranslation.width > 260)
              if far {
                withAnimation(.smooth(duration: 0.22)) { drag = 600 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { close() }
              } else {
                withAnimation(.smooth(duration: 0.25)) { drag = 0 }
              }
            } else if fromHeader {
              axis = nil
              fromHeader = false
              settle(max(0, g.translation.height), velocity: g.velocity.height)
            }
          })
      .onChange(of: touching) { _, now in
        guard !now else { return }
        // A drag the system cancels never reaches onEnded: put the panel back.
        DispatchQueue.main.async {
          if axis == .horizontal {
            axis = nil
            withAnimation(.smooth(duration: 0.25)) { drag = 0 }
          } else if fromHeader {
            axis = nil
            fromHeader = false
            withAnimation(.smooth(duration: 0.28)) { pull = 0 }
          }
        }
      }
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = max(1, $0) }
      .coordinateSpace(.named(Self.space))
  }
  private func settle(_ value: CGFloat, velocity: CGFloat) {
    let far = value > min(150, height * 0.28) || (value > 12 && velocity > 650)
    if far {
      TouchFeedback.light()
      // The removal transition carries the panel on down from where the finger left it.
      close()
    } else {
      withAnimation(.smooth(duration: 0.28)) { pull = 0 }
    }
  }
}

/// The lists a panel pulls from. Their pull-to-refresh stands aside: there a downward pull at the
/// top moves the panel instead.
@MainActor enum ReplyPanelPullClaim {
  static let scrolls = NSHashTable<UIScrollView>.weakObjects()
  static func owns(_ scroll: UIScrollView) -> Bool { scrolls.contains(scroll) }
}

/// Hands a downward pull on the panel's list to the panel once the list is at its top: the list
/// stays pinned there and the panel follows the finger, as the official comment panel does.
/// It only adds a target to the touched list's own pan, so scrolling and row taps are untouched.
private struct ReplyPanelPullMarker: UIViewRepresentable {
  /// The pull so far, 0 back at rest. Returns false while the panel is in another drag.
  let changed: (CGFloat) -> Bool
  /// The pull and the finger's downward speed (points/s) when it lifts.
  let released: (CGFloat, CGFloat) -> Void
  func makeUIView(context: Context) -> Marker { Marker() }
  func updateUIView(_ v: Marker, context: Context) {
    v.changed = changed
    v.released = released
    v.mount()
  }
  static func dismantleUIView(_ v: Marker, coordinator: ()) {
    v.clear()
    v.changed = nil
    v.released = nil
  }
  final class Watch: UIGestureRecognizer {
    weak var marker: Marker?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
      if let touch = touches.first { marker?.touch(touch) }
      state = .failed
    }
    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
  }
  final class Marker: UIView {
    var changed: ((CGFloat) -> Bool)?
    var released: ((CGFloat, CGFloat) -> Void)?
    private let watch = Watch()
    private weak var host: UIView?, scroll: UIScrollView?
    private var engaged = false, base: CGFloat = 0, last: CGFloat = 0, pull: CGFloat = 0
    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      watch.marker = self
      watch.cancelsTouchesInView = false
      watch.delaysTouchesBegan = false
      watch.delaysTouchesEnded = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      clear()
      if window != nil { DispatchQueue.main.async { [weak self] in self?.mount() } }
    }
    func mount() {
      guard let window, host == nil else { return }
      var r: UIResponder? = self
      while let value = r {
        if let c = value as? UIViewController, let v = c.viewIfLoaded, isDescendant(of: v),
          v.bounds.width > 30
        {
          host = v
          v.addGestureRecognizer(watch)
          return
        }
        r = value.next
      }
      host = window
      window.addGestureRecognizer(watch)
    }
    func clear() {
      host?.removeGestureRecognizer(watch)
      host = nil
      if let s = scroll {
        s.panGestureRecognizer.removeTarget(self, action: #selector(moved(_:)))
        ReplyPanelPullClaim.scrolls.remove(s)
      }
      scroll = nil
      engaged = false
      pull = 0
    }
    func touch(_ touch: UITouch) {
      guard let window, bounds.contains(touch.location(in: self)), let hit = touch.view else { return }
      let frame = convert(bounds, to: window)
      var a: UIView? = hit
      while let v = a, v !== host {
        // The thread's list: wide and tall, not a strip of pictures inside a reply.
        if let s = v as? UIScrollView, s.isScrollEnabled, !(s is UITextView),
          s.contentSize.width <= s.bounds.width + 2, s.bounds.width >= bounds.width * 0.6,
          s.bounds.height >= bounds.height * 0.5
        {
          // The panel's own list (it starts inside the panel; its bottom may run on under the
          // home indicator), not a page scroller the panel floats over.
          let f = s.convert(s.bounds, to: window)
          guard f.minY >= frame.minY - 1, f.minY <= frame.minY + frame.height * 0.5 else { return }
          if scroll !== s {
            if let old = scroll {
              old.panGestureRecognizer.removeTarget(self, action: #selector(moved(_:)))
              ReplyPanelPullClaim.scrolls.remove(old)
            }
            scroll = s
            s.panGestureRecognizer.addTarget(self, action: #selector(moved(_:)))
          }
          ReplyPanelPullClaim.scrolls.add(s)
          return
        }
        a = v.superview
      }
    }
    @objc private func moved(_ g: UIPanGestureRecognizer) {
      guard let s = scroll, g === s.panGestureRecognizer, let window else { return }
      let top = -s.adjustedContentInset.top
      // In window points: the panel moves under the finger, the window does not.
      let t = g.translation(in: window)
      switch g.state {
      case .began:
        engaged = false
        pull = 0
        last = t.y
      case .changed:
        let step = t.y - last
        last = t.y
        if !engaged {
          // Only at the list's top, for a downward and mostly vertical move.
          guard s.contentOffset.y <= top + 0.5, step > 0, abs(t.y) > abs(t.x) else { return }
          engaged = true
          base = t.y - max(step, top - s.contentOffset.y)
        }
        pull = max(0, t.y - base)
        guard pull > 0, changed?(pull) == true else {
          // Back up past where it began: the list scrolls again from its top.
          engaged = false
          pull = 0
          _ = changed?(0)
          return
        }
        if s.contentOffset.y != top { s.contentOffset = CGPoint(x: s.contentOffset.x, y: top) }
      case .ended, .cancelled, .failed:
        guard engaged else { return }
        engaged = false
        let velocity = g.state == .ended ? g.velocity(in: window).y : 0
        let value = g.state == .ended ? pull : 0
        pull = 0
        if velocity >= 0 {
          // No bounce or fling of the list underneath as the panel settles or leaves.
          s.piliStopScrolling()
          s.contentOffset = CGPoint(x: s.contentOffset.x, y: top)
        }
        released?(value, velocity)
      default:
        break
      }
    }
  }
}

/// Places the panels from the player's lower edge down, following the paused player as it
/// folds (only this view observes the fold, so scrolling doesn't re-render the page).
struct FoldAwareReplyPanels: View {
  let fold: PanelFold
  let active: Bool
  let playerHeight: CGFloat
  @Binding var items: [ReplyPanelItem]
  var body: some View {
    ReplyPanelStack(items: $items)
      .padding(.top, playerHeight - fold.progress(active) * fold.limit)
  }
}
