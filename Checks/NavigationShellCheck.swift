import Foundation

@main enum NavigationShellCheck {
  static func main() throws {
    let old = Data(#"{"tabs":["mine","home"],"launch":"mine","channels":["推荐"]}"#.utf8)
    var config = try JSONDecoder().decode(NavigationLayout.self, from: old)
    try config.validate()
    precondition(
      config.tabs == [.mine, .home] && config.mineTabs == [.favorite] && config.hideMode == .sync
        && config.tabletNav)
    config.mineTabs = [.subscribed, .history, .later]
    config.sidebar = true
    config.iconOnly = true
    config.hideMode = .instant
    let round = try JSONDecoder().decode(NavigationLayout.self, from: JSONEncoder().encode(config))
    precondition(config == round)
    let d = UserDefaults(suiteName: "ui-nav-test-" + UUID().uuidString)!
    try round.save(d)
    precondition(NavigationLayout.current(d) == round)
    var invalid = round
    invalid.mineTabs = [.history, .history]
    do {
      try invalid.validate()
      preconditionFailure("duplicate mine shelf")
    } catch {}
    invalid.mineTabs = []
    try invalid.validate()
    precondition(NavigationRules.sidebar(forced: false, width: 780, height: 380))
    precondition(!NavigationRules.sidebar(forced: false, width: 380, height: 780))
    precondition(NavigationRules.fraction(1, delta: 26, atTop: false, mode: .sync) == 0.5)
    precondition(NavigationRules.fraction(0.5, delta: 100, atTop: false, mode: .sync) == 0)
    precondition(NavigationRules.fraction(0, delta: -50, atTop: true, mode: .sync) == 1)
    precondition(NavigationRules.fraction(1, delta: 2, atTop: false, mode: .instant) == 0)
    let rows: [String: Any] = [
      "list": [
        ["kid": 12, "history": ["business": "article-list", "oid": 567, "cid": 777]],
        ["kid": 12, "history": ["business": "article", "oid": 567]],
        ["kid": 21, "progress": 18, "history": ["business": "pgc", "epid": 41, "oid": 1]],
        [
          "kid": 32, "progress": -1, "duration": 100,
          "history": ["business": "archive", "bvid": "BV1fK4y1t7hj", "page": 3],
        ],
        ["kid": 3, "live_status": 0, "history": ["business": "live", "oid": 123]],
        [
          "kid": 4, "uri": "https://www.bilibili.com/cheese/play/ep99",
          "history": ["business": "cheese", "oid": 9],
        ],
        ["kid": 33, "progress": 0, "history": ["business": "archive", "oid": 15, "page": 2]],
        ["kid": 34, "history": ["business": "archive", "oid": 16, "page": 1]],
        ["kid": 35, "progress": 26, "history": ["business": "archive", "oid": 17, "page": 4]],
      ]
    ]
    let list = try JSONDecoder().decode(
      MineHistoryPage.self, from: JSONSerialization.data(withJSONObject: rows)
    ).list!.compactMap(\.entry)
    precondition(
      Set(list.map(\.id)).count == 9 && list[0].target == .link(.article(777))
        && list[1].target == .link(.article(567)))
    precondition(
      list[2].target == .link(.positioned(.episode(41), 18))
        && list[3].target == .link(.positioned(.video("BV1fK4y1t7hj", 3), 0)))
    precondition(
      list[3].progress == 1 && list[4].target == .unavailable(list[4].id)
        && list[5].target == .courseHistory(99, true, 9, nil))
    precondition(SharedLink.parse("https://www.bilibili.com/medialist/detail/ml76614671") == .favoriteFolder(76614671))
    precondition(SharedLink.parse("bilibili://medialist/76614671") == .favoriteFolder(76614671))
    precondition(SharedLink.parse("https://space.bilibili.com/123/lists/789") == .subscriptionSeason(789))
    precondition(SharedLink.parse("https://space.bilibili.com/123/channel/collectiondetail?sid=789") == .subscriptionSeason(789))
    precondition(list[6].target == .link(.positioned(.archive(15, 2), 0))
      && list[7].target == .link(.archive(16, 1))
      && list[8].target == .link(.positioned(.archive(17, 4), 26)))
    print(
      "Navigation: old/ordered/empty layouts, scope, scroll modes and mixed-history destinations passed"
    )
  }
}
