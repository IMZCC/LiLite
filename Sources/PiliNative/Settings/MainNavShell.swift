import SwiftUI
import Observation

private struct ShellContextKey: EnvironmentKey { static let defaultValue: NavigationChrome? = nil }
private struct ProfileShortcutKey:EnvironmentKey {static let defaultValue:(@MainActor ()->Void)?=nil}
private struct ShellTabKey: EnvironmentKey { static let defaultValue: MainTab? = nil }
private struct HomeSearchCollapseKey: EnvironmentKey { static let defaultValue = false }
private struct SystemSearchTabKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
  var usesSystemSearchTab: Bool {
    get { self[SystemSearchTabKey.self] }
    set { self[SystemSearchTabKey.self] = newValue }
  }
  fileprivate var navChrome: NavigationChrome? {
    get { self[ShellContextKey.self] }
    set { self[ShellContextKey.self] = newValue }
  }
  var openPersonalPage:(@MainActor ()->Void)? {get {self[ProfileShortcutKey.self]} set{self[ProfileShortcutKey.self]=newValue}}
  var scrollHomeChannelToTop: @MainActor () -> Void {
    let chrome = navChrome
    return { if chrome?.active == .home { chrome?.top(allowRefresh: false) } }
  }
  fileprivate var owningTab: MainTab? {
    get { self[ShellTabKey.self] }
    set { self[ShellTabKey.self] = newValue }
  }
  var collapseHomeSearch: Bool {
    get { self[HomeSearchCollapseKey.self] }
    set { self[HomeSearchCollapseKey.self] = newValue }
  }
}
@MainActor @Observable private final class NavigationChrome {
  private(set) var visible: [MainTab: Bool] = [:]
  private(set) var fraction = 1.0
  @ObservationIgnored private var owners: [MainTab: UUID] = [:]
  @ObservationIgnored var listen = false
  @ObservationIgnored var reduce = false
  @ObservationIgnored var mode = NavigationHideMode.sync
  @ObservationIgnored var active = MainTab.home
  @ObservationIgnored private var mounted: [MainTab: WeakView] = [:]
  @ObservationIgnored private var touched: [MainTab: WeakView] = [:]
  @ObservationIgnored var reselect = RootTabReselect()
  private final class WeakView {
    weak var value: UIView?
    init(_ view: UIView) { value = view }
  }
  func mount(_ view: UIView, for tab: MainTab) { mounted[tab] = WeakView(view) }
  func show(_ t: MainTab, _ token: UUID) {
    owners[t] = token
    if visible[t] != true { visible[t] = true }
    if active == t { reset() }
  }
  func leave(_ t: MainTab, _ token: UUID) {
    guard owners[t] == token else { return }
    visible[t] = false
  }
  func reset() { if fraction != 1 { fraction = 1 } }
  @ObservationIgnored private var travel: CGFloat = 0
  /// The header follows the finger at a calm rate after a small dead zone (so small
  /// corrections never twitch it). Only the release needs a settling animation.
  func drag(_ t: MainTab, delta: CGFloat, top: Bool, scroll: UIScrollView) {
    guard t == active, visible[t] == true else { return }
    if touched[t]?.value !== scroll { touched[t] = WeakView(scroll) }
    guard listen, delta.isFinite else { return }
    if top {
      travel = 0
      settle(1)
      return
    }
    if delta != 0, (delta > 0) != (travel > 0) { travel = 0 }
    travel += delta
    guard abs(travel) > 14 else { return }
    if mode == .instant || reduce {
      settle(travel > 0 ? 0 : 1)
      return
    }
    let v = max(0, min(1, fraction - Double(delta) / 96))
    guard v != fraction else { return }
    fraction = v
  }
  func release(_ t: MainTab, velocity: CGFloat) {
    guard t == active, visible[t] == true, listen else { return }
    travel = 0
    guard fraction > 0, fraction < 1 else { return }
    let target: Double = velocity > 260 ? 0 : velocity < -260 ? 1 : (fraction < 0.5 ? 0 : 1)
    settle(target)
  }
  private func settle(_ value: Double) {
    guard fraction != value else { return }
    withAnimation(reduce ? nil : .smooth(duration: 0.3)) { fraction = value }
  }
  func top(allowRefresh: Bool = true) {
    guard visible[active] == true, let root = mounted[active]?.value, root.window != nil else {
      return
    }
    let scroll =
      (touched[active]?.value as? UIScrollView).flatMap {
        NavScrollAttachment.visible($0,in:root) ? $0:nil
      }
      ?? NavScrollAttachment.primaryScroll(in: root)
    guard let s = scroll else { return }
    let leadingY = -s.adjustedContentInset.top
    if allowRefresh, reselect.shouldRefresh(active, atTop:s.contentOffset.y <= leadingY+1, now:ProcessInfo.processInfo.systemUptime) {
      if !NativePullRefresh.repeatTab(on:s), let ui=s.refreshControl, !ui.isRefreshing { ui.sendActions(for:.valueChanged) }
    }
    s.setContentOffset(CGPoint(x: s.contentOffset.x, y: leadingY), animated: !reduce)
    reset()
  }
}

private struct TabRootMarker: ViewModifier {
  let tab: MainTab
  @Environment(\.navChrome) private var chrome
  @Environment(\.owningTab) private var owner
  @State private var token = UUID()
  func body(content: Content) -> some View {
    content.background {
      if let chrome, owner == tab {
        NavScrollAttachment(mounted: { chrome.mount($0, for: tab) }, change: { delta, top, scroll in
          chrome.drag(tab, delta: delta, top: top, scroll: scroll)
        }, ended: { velocity in chrome.release(tab, velocity: velocity) })
        .allowsHitTesting(false)
      }
    }.onAppear { if owner == tab { chrome?.show(tab, token) } }
      .onDisappear { if owner == tab { chrome?.leave(tab, token) } }
  }
}
extension View {
  func piliTabRoot(_ tab: MainTab) -> some View { modifier(TabRootMarker(tab: tab)) }
  func homeSearchMotion(travel: CGFloat) -> some View { modifier(HomeSearchMotion(travel: travel)) }
  func homeSearchControls() -> some View { modifier(HomeSearchControls()) }
}
private struct HomeSearchMotion: ViewModifier {
  @Environment(\.navChrome) private var chrome
  let travel: CGFloat
  func body(content: Content) -> some View {
    content.offset(y: -travel * (1 - (chrome?.fraction ?? 1)))
  }
}
private struct HomeSearchControls: ViewModifier {
  @Environment(\.navChrome) private var chrome
  @Environment(\.collapseHomeSearch) private var enabled
  func body(content: Content) -> some View {
    let accessible = !enabled || (chrome?.fraction ?? 1) > 0.65
    content.allowsHitTesting(accessible).accessibilityHidden(!accessible)
  }
}

/// Like the original, the main columns are a tab bar unless 改用侧边栏 (`useSideBar`) is on: on iPad
/// and other wide windows a tab bar at the top, as in the App Store, so a sidebar never takes the
/// place of a page's back button. With the setting on, the sidebar is the default only in
/// landscape (as in Files and Mail); portrait keeps the tab bar. Rotating changes only the default
/// placement, never this view's identity.
private struct AdaptiveTabStyle: ViewModifier {
  let sidebar: Bool, landscape: Bool
  @ViewBuilder func body(content: Content) -> some View {
    if #available(iOS 18, *) {
      if sidebar {
        content.tabViewStyle(.sidebarAdaptable)
          .defaultAdaptableTabBarPlacement(landscape ? .sidebar : .tabBar)
      } else {
        content.tabViewStyle(.tabBarOnly)
      }
    } else {
      content
    }
  }
}
struct MainNavShell: View {
  let layout: NavigationLayout, badge: (MainTab) -> Text?
  @Binding var active: MainTab
  @Binding var incoming: [MainTab: IncomingRoute]
  @State private var chrome = NavigationChrome()
  /// 改用侧边栏 is read once: the two tab view styles are different views, so switching them
  /// while running would rebuild every column and drop its navigation (the settings page the
  /// switch was made on included). It applies from the next launch.
  @State private var sidebar = NavigationLayout.current().sidebar
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
  @Environment(\.accessibilityReduceMotion) private var reduce
  enum Shortcut: Int, Identifiable {
    case search, profile
    var id: Self { self }
  }
  @State private var shortcut: Shortcut?
  /// Content tabs in the user's order; search always uses the system search tab role.
  private var contentTabs: [MainTab] { layout.tabs.filter { $0 != .search } }
  var body: some View {
    let collapseSearch = layout.collapseTop && !voiceOver
    tabs(collapseSearch: collapseSearch)
    .piliTabBarMinimize(onScrollDown: layout.collapseBottom && !voiceOver)
    .environment(\.navChrome, chrome)
    .environment(\.usesSystemSearchTab, layout.tabs.contains(.search))
    .environment(\.openPersonalPage, {
      if layout.tabs.contains(.mine) { select(.mine) } else { shortcut = .profile }
    })
    .onChange(of: incoming[active]?.id) { _, id in if id != nil { shortcut = nil } }
    .onChange(of: active, initial: true) { _, value in
      chrome.reselect = RootTabReselect()
      chrome.active = value
      chrome.reset()
    }
    .onChange(of: "\(layout.collapseTop):\(voiceOver):\(reduce)", initial: true) { _, _ in
      chrome.listen = !voiceOver && layout.collapseTop
      chrome.mode = .sync
      chrome.reduce = reduce
      chrome.reset()
    }
    .background {
      // ⌘1… and ⌘F live in the app's 前往 menu; without a search column ⌘F opens search here.
      if !layout.tabs.contains(.search) {
        Button("搜索") { shortcut = .search }.keyboardShortcut("f", modifiers: .command)
          .frame(width: 0, height: 0).clipped().accessibilityHidden(true)
      }
      if !layout.directBack, let first = layout.tabs.first, first != active {
        Button("返回首个栏目") { select(first) }.keyboardShortcut(.escape, modifiers: [])
          .frame(width: 0, height: 0).clipped().accessibilityHidden(true)
      }
    }
    .piliSheet(item: $shortcut) { shortcut in
      Group {
        switch shortcut {
        case .search: SearchView()
        case .profile: ProfileView()
        }
      }.environment(\.navChrome, nil).environment(\.owningTab, nil)
        .presentationDragIndicator(.visible)
    }
  }
  /// iOS 18+: `Tab` values with the search role (its own button) and the adaptive sidebar.
  /// iOS 17: the classic tab items, search last.
  @ViewBuilder private func tabs(collapseSearch: Bool) -> some View {
    if #available(iOS 18, *) {
      TabView(selection: $active) {
        ForEach(contentTabs) { tab in
          Tab(tab.title, systemImage: tab.icon, value: tab) {
            root(tab, collapseSearch: collapseSearch)
          }.badge(badge(tab))
        }
        if layout.tabs.contains(.search) {
          Tab(MainTab.search.title, systemImage: MainTab.search.icon, value: MainTab.search, role: .search) {
            root(.search, collapseSearch: false)
          }
        }
      }
      // Only read the orientation when it matters, so turning the device (e.g. into fullscreen
      // video) never re-evaluates the whole shell.
      .modifier(AdaptiveTabStyle(sidebar: sidebar, landscape: sidebar && WindowCanvas.shared.landscape))
    } else {
      TabView(selection: $active) {
        ForEach(contentTabs) { tab in
          root(tab, collapseSearch: collapseSearch)
            .tabItem { Label(tab.title, systemImage: tab.icon) }
            .tag(tab)
            .badge(badge(tab))
        }
        if layout.tabs.contains(.search) {
          root(.search, collapseSearch: false)
            .tabItem { Label(MainTab.search.title, systemImage: MainTab.search.icon) }
            .tag(MainTab.search)
        }
      }
    }
  }
  private func root(_ tab: MainTab, collapseSearch: Bool) -> some View {
    tab.screen
      .environment(\.incomingTabLink, Binding(get: { incoming[tab] }, set: { incoming[tab] = $0 }))
      .environment(\.activeCatalogPage, active == tab)
      .environment(\.preparedCatalogPage, active == tab)
      .environment(\.owningTab, tab)
      .environment(\.collapseHomeSearch, tab == .home && collapseSearch)
      .background {
        NativeTabReselect(tab: tab) { selected in
          if chrome.active == selected { chrome.top() }
        }.frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
      }
  }
  private func select(_ t: MainTab) {
    TouchFeedback.light()
    guard t != active else {
      chrome.top()
      chrome.reset()
      return
    }
    active = t
  }
}
