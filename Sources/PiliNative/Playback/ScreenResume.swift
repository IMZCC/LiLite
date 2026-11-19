import SwiftUI

/// The playback page on screen, so that a scene the system ends while it sits in the background
/// (to reclaim memory) reopens on it instead of the home page, as the official app does. The app
/// keeps it in `@SceneStorage`, which survives only such a restart: a user who swipes the app
/// away from the switcher starts from home again.
@MainActor final class ScreenResume {
  static let shared = ScreenResume()
  private struct Entry { let id: UUID; var link: @MainActor () -> String? }
  /// Pages in the order they last came on screen; the last one is in front.
  private var entries: [Entry] = []
  func enter(_ id: UUID, link: @escaping @MainActor () -> String?) {
    entries.removeAll { $0.id == id }
    entries.append(.init(id: id, link: link))
  }
  /// The page's identity changed (another part, the next video) without it leaving the screen.
  func update(_ id: UUID, link: @escaping @MainActor () -> String?) {
    guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
    entries[i].link = link
  }
  func leave(_ id: UUID) { entries.removeAll { $0.id == id } }
  var current: String? { entries.last?.link() }

  static func video(_ bvid: String, cid: Int64?, seconds: Double) -> String? {
    guard !bvid.isEmpty else { return nil }
    var link = "https://www.bilibili.com/video/" + bvid
    var query = [String]()
    if let cid, cid > 0 { query.append("cid=\(cid)") }
    if seconds.isFinite, seconds >= 1 { query.append("t=\(Int(seconds))") }
    if !query.isEmpty { link += "?" + query.joined(separator: "&") }
    return link
  }
  static func episode(_ id: Int64, seconds: Double) -> String? {
    guard id > 0 else { return nil }
    let time = seconds.isFinite && seconds >= 1 ? "?t=\(Int(seconds))" : ""
    return "https://www.bilibili.com/bangumi/play/ep\(id)" + time
  }
}

extension View {
  /// Marks this page as the one a restored scene reopens while it is on screen. `key` names what
  /// it shows; the link is read when the app goes to the background, so it carries the position.
  func screenResume(key: String, link: @escaping @MainActor () -> String?) -> some View {
    modifier(ScreenResumeMarker(key: key, link: link))
  }
}

private struct ScreenResumeMarker: ViewModifier {
  let key: String
  let link: @MainActor () -> String?
  @State private var id = UUID()
  func body(content: Content) -> some View {
    content
      .onAppear { ScreenResume.shared.enter(id, link: link) }
      .onDisappear { ScreenResume.shared.leave(id) }
      .onChange(of: key) { _, _ in ScreenResume.shared.update(id, link: link) }
  }
}

/// Keeps the page on screen in the scene's restoration state as the app leaves the foreground,
/// and reopens it when the system restores a scene it ended. `@SceneStorage` lives only inside the
/// scene's views, and survives a system termination but not a swipe-away in the app switcher.
struct SceneResume: ViewModifier {
  @Binding var active: MainTab
  @Binding var incoming: [MainTab: IncomingRoute]
  let layout: NavigationLayout
  /// The account is in place: a change of account rebuilds the columns, so open after it.
  let ready: Bool
  @Environment(\.scenePhase) private var phase
  @SceneStorage("pili.resume.route") private var route = ""
  @SceneStorage("pili.resume.tab") private var tab = ""
  @State private var consumed = false
  func body(content: Content) -> some View {
    content
      .onChange(of: phase) { _, now in
        // Inactive comes first on the way out, before the system saves the scene's state.
        guard now != .active else { return }
        route = ScreenResume.shared.current ?? ""
        tab = active.rawValue
      }
      .onChange(of: ready, initial: true) { _, ready in
        guard ready, !consumed else { return }
        consumed = true
        let saved = route
        route = ""
        guard !saved.isEmpty, incoming.isEmpty, let link = SharedLink.parse(saved) else { return }
        if let column = MainTab(rawValue: tab), layout.tabs.contains(column) { active = column }
        incoming[active] = IncomingRoute(link: link)
      }
  }
}
