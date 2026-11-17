import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@main enum InterfaceAcceptanceCheck {
  static func reject(_ f: () throws -> Void) {
    do {
      try f()
      fatalError("invalid input accepted")
    } catch {}
  }
  static func main() throws {
    var pulse = TouchPulseGate()
    precondition(!pulse.claim(enabled: false) && pulse.claim(enabled: true))
    precondition(!pulse.claim(enabled: true))
    pulse.nextTurn()
    precondition(pulse.claim(enabled: true))
    var tap = RootTabReselect()
    precondition(!tap.shouldRefresh(.home, atTop: false, now: 10))
    precondition(tap.shouldRefresh(.home, atTop: false, now: 10.3))
    precondition(!tap.shouldRefresh(.home, atTop: true, now: 10.6))
    precondition(tap.shouldRefresh(.home, atTop: true, now: 10.9))
    precondition(!tap.shouldRefresh(.mine, atTop: true, now: 12))
    precondition(
      NavigationRules.firstChannel([.rank, .recommended, .live]) == .recommended
        && NavigationRules.firstChannel([.live, .cinema]) == .live)
    precondition(
      NavigationRules.splitSettings(width: 844, height: 390, accessibility: false)
        && !NavigationRules.splitSettings(width: 390, height: 844, accessibility: false)
        && !NavigationRules.splitSettings(width: 844, height: 390, accessibility: true))
    for mask in 0...31 {
      let hidden = UnreadTotals.visibleMask(mask, hideLikes: true)
      let shown = UnreadTotals.visibleMask(mask, hideLikes: false)
      precondition(
        (hidden & UnreadKind.like.bit) == 0 && (shown & ~UnreadKind.like.bit) == hidden
          && shown == mask)
    }
    precondition(
      UnreadTotals.messages(
        UnreadTotals.visibleMask(31, hideLikes: true), ["follow_unread": 3],
        ["like": 99, "reply": 2]) == 5)
    for mode in PageMotion.allCases {
      precondition(
        !mode.custom(reduced: true, interactivePop: false)
          && !mode.custom(reduced: false, interactivePop: true))
      precondition(
        mode.custom(reduced: false, interactivePop: false) == ![
          PageMotion.native, .cupertino, .cupertinoDialog,
        ].contains(mode))
    }
    precondition(PageMotion.allCases.count == 17)
    for b in [-0.50, 0, 0.50] {
      let spring = ScrollSpring(duration: 0.42, bounce: b)!
      precondition(abs(spring.duration - 0.42) < 0.00001 && abs(spring.bounce - b) < 0.00001)
      let a = spring.state(offset: 12, velocity: -4, after: 0)
      let z = spring.state(offset: 12, velocity: -4, after: 8)
      precondition(
        abs(a.0 - 12) < 0.000001 && abs(a.1 + 4) < 0.000001 && abs(z.0) < 0.005 && abs(z.1) < 0.005)
    }
    precondition(
      ScrollSpring([0, 1, 1]) == nil && ScrollSpring(duration: .infinity, bounce: 0) == nil)
    for i in 1...9 {
      let face = TypefaceChoice(
        name: "Fixture", file: String(repeating: "a", count: 64) + ".ttf", weight: i,
        scale: i == 1 ? 0.85 : 1.6)
      let d = try face.encoded()
      precondition(TypefaceChoice.decode(d) == face)
    }
    var bad = TypefaceChoice()
    bad.file = "../foreign.ttf"
    bad.name = "Fixture"
    reject { try bad.validate() }
    bad.file = String(repeating: "b", count: 64) + ".ttf\n"
    reject { try bad.validate() }
    precondition(
      InterfacePresentation.dimImage(loaded: true, dark: true, tint: 0x8040_2010)
        && !InterfacePresentation.dimImage(loaded: false, dark: true, tint: 0x8040_2010)
        && !InterfacePresentation.dimImage(loaded: true, dark: false, tint: 0x8040_2010)
        && !InterfacePresentation.dimImage(loaded: true, dark: true, tint: 0xffff_ffff))
    let c = InterfacePresentation.colorChannels(0x8040_2010)
    precondition(c.a == 128 / 255.0 && c.r == 64 / 255.0 && c.g == 32 / 255.0 && c.b == 16 / 255.0)
    precondition(
      InterfacePresentation.refreshChoices(maximum: 60) == [24, 30, 48, 60]
        && InterfacePresentation.refreshChoices(maximum: 120) == [24, 30, 48, 60, 90, 120])
    precondition(
      InterfacePresentation.columns(width: 504, gap: 12, desired: 240, accessible: false) == 2
        && InterfacePresentation.columns(width: 504.1, gap: 12, desired: 240, accessible: false)
          == 3
        && InterfacePresentation.columns(width: 1024, gap: 12, desired: 160, accessible: true) == 1)
    let dname = "Pili.interface.fixture." + UUID().uuidString
    let d = UserDefaults(suiteName: dname)!
    defer { d.removePersistentDomain(forName: dname) }
    func result(_ path: String, _ cellular: Bool? = nil) -> String {
      SettingSearchRow.all.first { $0.anchor == path && $0.cellular == cellular }!.location(d)
        .anchor
    }
    precondition(result("SettingsView/图片叠加色") == "SettingsView/深色模式调暗网络图片")
    d.set(0xff06_0606, forKey: "images.nightTint")
    precondition(result("SettingsView/图片叠加色") == "SettingsView/图片叠加色")
    d.set(true, forKey: "appearance.systemTint")
    precondition(result("ThemePicker/自定义颜色") == "ThemePicker/跟随系统强调色")
    precondition(result("MediaProfilePanel/添加编码", true) == "MediaProfilePanel/与 Wi-Fi 相同")
    d.set(Data(#"{"wifiCodecs":["AVC","HEVC","AV1"]}"#.utf8), forKey: "play.networkMedia")
    precondition(result("MediaProfilePanel/添加编码", false) == "MediaProfilePanel/视频编码优先顺序")
    let req = try AccountExitRequest.make(
      header: "DedeUserID=101; SESSDATA=synthetic", csrf: "x+y&z")
    precondition(
      req.url?.absoluteString == "https://passport.bilibili.com/login/exit/v2"
        && req.httpMethod == "POST" && !req.httpShouldHandleCookies
        && req.httpBody == Data("biliCSRF=x%2By%26z".utf8))
    try AccountExitRequest.check(Data(#"{"code":0}"#.utf8), status: 200)
    reject { try AccountExitRequest.check(Data(#"{"code":-101}"#.utf8), status: 200) }
    reject { try AccountExitRequest.check(Data(#"{"code":0}"#.utf8), status: 302) }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
      "PiliUIFixture-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    let kept = root.appendingPathComponent("Offline", isDirectory: true)
    for n in LocalResetPolicy.accountFolders + ["Offline", "LocalFolderAccess"] {
      let folder = root.appendingPathComponent(n, isDirectory: true)
      try fm.createDirectory(at: folder, withIntermediateDirectories: false)
      try Data("fixture".utf8).write(to: folder.appendingPathComponent("example"))
    }
    let q = try LocalResetPolicy.removeManagedData(in: root)!
    let file = root.appendingPathComponent("ReplyArchive/example")
    precondition(!fm.fileExists(atPath: file.path) && fm.fileExists(atPath: kept.path))
    try LocalResetPolicy.finish(q, in: root, restore: true)
    precondition(fm.fileExists(atPath: file.path))
    let q2 = try LocalResetPolicy.removeManagedData(in: root)!
    try LocalResetPolicy.finish(q2, in: root, restore: false)
    precondition(
      !fm.fileExists(atPath: file.path)
        && fm.fileExists(atPath: kept.appendingPathComponent("example").path))
    try fm.createSymbolicLink(
      at: root.appendingPathComponent("PiliNotebook"), withDestinationURL: kept)
    reject { _ = try LocalResetPolicy.removeManagedData(in: root) }
    precondition(fm.fileExists(atPath: kept.appendingPathComponent("example").path))
    print(
      "PASS interface: root reselect, startup channel, adaptive layout, 17 motions, three spring regimes, font and frame limits, conditional search targets, scoped reset, isolated account exit request"
    )
  }
}
