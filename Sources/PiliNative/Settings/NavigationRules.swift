import Foundation

enum MineSection: Int, Codable, CaseIterable, Identifiable {
  case favorite, history, later, subscribed
  var id: Self { self }
  var label: String { ["我的收藏", "观看记录", "稍后再看", "我的订阅"][rawValue] }
}
enum NavigationHideMode: Int, Codable, CaseIterable, Identifiable {
  case instant, sync
  var id: Self { self }
  var label: String { self == .instant ? "即时" : "跟随滚动" }
}
struct RootTabReselect {
  private var last: TimeInterval?, refreshed: TimeInterval?
  mutating func shouldRefresh(_ tab: MainTab, atTop: Bool, now: TimeInterval) -> Bool {
    guard tab == .home || tab == .dynamics else { return false }
    let quick = last.map { now >= $0 && now - $0 < 0.5 } ?? false
    last = now
    guard quick || atTop, refreshed.map({ now >= $0 && now - $0 >= 0.5 }) ?? true else { return false }
    refreshed = now; return true
  }
}
enum NavigationRules {
  static func firstChannel(_ visible: [HomeChannel]) -> HomeChannel {
    visible.contains(.recommended) ? .recommended : visible.first ?? .recommended
  }
  static func splitSettings(width: Double, height: Double, accessibility: Bool) -> Bool {
    !accessibility && width >= 680 && width > height && height > 0
  }
  static func sidebar(forced: Bool, width: Double, height: Double) -> Bool {
    forced || width > height
  }
  static func fraction(
    _ start: Double, delta: Double, atTop: Bool, mode: NavigationHideMode,
    reduceMotion: Bool = false
  ) -> Double {
    guard delta.isFinite && start.isFinite else { return 1 }
    if atTop { return 1 }
    if abs(delta) < 0.15 { return start }
    if mode == .instant || reduceMotion { return delta > 0 ? 0 : 1 }
    return max(0, min(1, start - delta / 52))
  }
}

enum MainTab: String, Codable, CaseIterable, Identifiable {
  case home, search, dynamics, mine
  var id: Self { self }
  var title: String {
    switch self {
    case .home: "首页"
    case .search: "搜索"
    case .dynamics: "动态"
    case .mine: "我的"
    }
  }
  var icon: String {
    switch self {
    case .home: "play.rectangle"
    case .search: "magnifyingglass"
    case .dynamics: "person.2"
    case .mine: "person.crop.circle"
    }
  }
}
enum HomeChannel: String, Codable, CaseIterable, Identifiable {
  case live = "直播"
  case recommended = "推荐"
  case popular = "热门"
  case rank = "分区"
  case bangumi = "番剧"
  case cinema = "影视"
  var id: Self { self }
}
struct NavigationLayout: Codable, Equatable {
  static let key = "navigation.layout"
  /// The original's three columns; search is reached from the home header, never a column.
  static let columns: [MainTab] = [.home, .dynamics, .mine]
  var tabs = Self.columns, channels = HomeChannel.allCases
  var launch = MainTab.home
  var sidebar = false, iconOnly = false, tabletNav = true, floating = false, spaciousBar = true
  var collapseTop = true, collapseBottom = true, animateTabs = false, directBack = false
  var hideMode = NavigationHideMode.sync
  var mineTabs: [MineSection] = [.favorite]
  init() {}
  private enum CodingKeys: String, CodingKey {
    case tabs, channels, launch, sidebar, iconOnly, tabletNav, floating, spaciousBar, collapseTop,
      collapseBottom, animateTabs, directBack, hideMode, mineTabs
  }
  init(from d: Decoder) throws {
    self.init()
    let c = try d.container(keyedBy: CodingKeys.self)
    // Older layouts may still list a search column; the original has none.
    let stored = (try c.decodeIfPresent([MainTab].self, forKey: .tabs) ?? tabs).filter { $0 != .search }
    tabs = stored.isEmpty ? Self.columns : stored
    channels = try c.decodeIfPresent([HomeChannel].self, forKey: .channels) ?? channels
    launch = try c.decodeIfPresent(MainTab.self, forKey: .launch) ?? launch
    if !tabs.contains(launch) { launch = tabs.contains(.home) ? .home : tabs[0] }
    sidebar = try c.decodeIfPresent(Bool.self, forKey: .sidebar) ?? sidebar
    iconOnly = try c.decodeIfPresent(Bool.self, forKey: .iconOnly) ?? iconOnly
    tabletNav = try c.decodeIfPresent(Bool.self, forKey: .tabletNav) ?? tabletNav
    floating = try c.decodeIfPresent(Bool.self, forKey: .floating) ?? floating
    spaciousBar = try c.decodeIfPresent(Bool.self, forKey: .spaciousBar) ?? spaciousBar
    collapseTop = try c.decodeIfPresent(Bool.self, forKey: .collapseTop) ?? collapseTop
    collapseBottom = try c.decodeIfPresent(Bool.self, forKey: .collapseBottom) ?? collapseBottom
    animateTabs = try c.decodeIfPresent(Bool.self, forKey: .animateTabs) ?? animateTabs
    directBack = try c.decodeIfPresent(Bool.self, forKey: .directBack) ?? directBack
    hideMode = try c.decodeIfPresent(NavigationHideMode.self, forKey: .hideMode) ?? hideMode
    mineTabs = try c.decodeIfPresent([MineSection].self, forKey: .mineTabs) ?? mineTabs
  }
  func validate() throws {
    guard Set(mineTabs).count == mineTabs.count else { throw ServiceError("我的栏目有重复项") }
    guard !tabs.isEmpty, Set(tabs).count == tabs.count, tabs.contains(launch), !channels.isEmpty,
      Set(channels).count == channels.count
    else { throw ServiceError("至少保留一个栏目和一个首页频道") }
  }
  private static let decoded = DecodedSettingCache<Self>()
  static func read(_ data: Data) -> Self {
    decoded.value(for: data) { bytes in
      guard let v = try? JSONDecoder().decode(Self.self, from: bytes), (try? v.validate()) != nil
      else { return .init() }
      return v
    }
  }
  static func current(_ d: UserDefaults = .standard) -> Self { read(d.data(forKey: key) ?? Data()) }
  func save(_ d: UserDefaults = .standard) throws {
    try validate()
    d.set(try JSONEncoder().encode(self), forKey: Self.key)
  }
}
