import SwiftUI

enum FeedPanelPosition: Int, CaseIterable, Identifiable {
  case top, leftFixed, rightFixed, leftDrawer, rightDrawer
  var id: Self { self }
  var label: String {
    switch self {
    case .top: "顶部"
    case .leftFixed: "左侧常驻"
    case .rightFixed: "右侧常驻"
    case .leftDrawer: "左侧抽屉"
    case .rightDrawer: "右侧抽屉"
    }
  }
  var drawer: Bool { self == .leftDrawer || self == .rightDrawer }
  static let key = "social.upPanelPosition"
  /// The reader's choice, or else: on a large window the official client's strip of followed
  /// UP 主 across the top (a column of avatars down the side wasted a sixth of an iPad's width on
  /// names broken over two lines); on a phone the side column, as before.
  @MainActor static func resolved(_ stored: Int?) -> Self {
    if let stored, let chosen = Self(rawValue: stored) { return chosen }
    return WindowCanvas.shared.large ? .top : .leftFixed
  }
  var leading: Bool { self == .leftFixed || self == .leftDrawer }
}

@MainActor final class FeedDirectoryState: ObservableObject {
  private enum Next: Hashable {
    case following(Int)
    case updates(String)
  }
  private var uid: String?, all = false, epoch = UUID(), seen = Set<Next>()
  private var next: Next?
  @Published private(set) var people: [DynamicPortal.Person] = []
  @Published private(set) var rooms: [DynamicPortal.Live.Room] = []
  @Published private(set) var liveCount = 0
  @Published private(set) var busy = false
  @Published private(set) var loaded = false
  @Published private(set) var more = false
  @Published private(set) var issue: String?
  @Published private(set) var me: AccountProfile?
  func profile(_ uid: String) async {
    if me.map({ String($0.mid) }) == uid { return }
    me = nil
    let p = try? await BiliAPI.shared.read(
      "/x/web-interface/nav", [:], expectedAccount: uid, as: AccountProfile.self)
    if !Task.isCancelled, p.map({ String($0.mid) }) == uid { me = p }
  }
  func configure(_ uid: String, all: Bool) async {
    if loaded && self.uid == uid && self.all == all { return }
    await refresh(uid, all: all)
  }
  func read(_ mid: Int64) {
    if let i = people.firstIndex(where: { $0.mid == mid }), people[i].has_update == true {
      people[i].has_update = false
    }
  }
  func refresh(_ uid: String, all: Bool) async {
    if self.uid != uid || self.all != all {
      people = []
      rooms = []
      liveCount = 0
      loaded = false
    }
    self.uid = uid
    self.all = all
    let token = UUID()
    epoch = token
    issue = nil
    busy = true
    more = false
    next = nil
    seen = []
    defer { if epoch == token { busy = false } }
    do {
      let portal = try await BiliAPI.shared.read(
        "/x/polymer/web-dynamic/v1/portal", ["up_list_more": "1", "web_location": "333.1365"],
        expectedAccount: uid, as: DynamicPortal.self)
      try Task.checkCancellation()
      guard epoch == token else { return }
      var roomIDs = Set<Int64>()
      var ids = Set<Int64>()
      rooms = (portal.live_users?.items ?? []).filter {
        ($0.room_id ?? 0) > 0 && roomIDs.insert($0.id).inserted
      }
      liveCount = max(
        rooms.count, portal.live_users?.count?.number.flatMap(Int.init(exactly:)) ?? 0)
      people = (portal.up_list?.items ?? []).filter { $0.mid > 0 && ids.insert($0.mid).inserted }
      next = all ? .following(1) : cursor(portal.up_list)
      more = next != nil
      loaded = true
    } catch { if epoch == token && !Task.isCancelled { issue = error.localizedDescription } }
  }
  private func cursor(_ users: DynamicPortal.Users?) -> Next? {
    guard users?.has_more == true, let token = users?.offset, !token.isEmpty else { return nil }
    return .updates(token)
  }
  func loadMore() async {
    guard let uid, !busy, let pending = next else { return }
    let token = epoch
    issue = nil
    busy = true
    defer { if epoch == token { busy = false } }
    do {
      let rows: [DynamicPortal.Person]
      let candidate: Next?
      switch pending {
      case .updates(let offset):
        let users = try await BiliAPI.shared.read(
          "/x/polymer/web-dynamic/v1/uplist",
          ["offset": offset, "platform": "web", "web_location": "333.1365"],
          expectedAccount: uid, as: DynamicPortal.Users.self)
        rows = users.items ?? []
        candidate = cursor(users)
      case .following(let page):
        struct Result: Decodable { let list: [DynamicPortal.Person]?, total: Int? }
        let response = try await BiliAPI.shared.read(
          "/x/relation/followings",
          [
            "vmid": uid, "pn": String(page), "ps": "50", "order": "desc", "order_type": "attention",
          ],
          expectedAccount: uid, as: Result.self)
        rows = response.list ?? []
        candidate =
          !rows.isEmpty && (response.total.map { page * 50 < $0 } ?? (rows.count == 50))
          ? .following(page + 1) : nil
      }
      try Task.checkCancellation()
      guard epoch == token else { return }
      var existing = Set(people.map(\.mid))
      people.append(contentsOf: rows.filter { $0.mid > 0 && existing.insert($0.mid).inserted })
      seen.insert(pending)
      next = candidate.flatMap { seen.contains($0) ? nil : $0 }
      more = next != nil
    } catch { if epoch == token && !Task.isCancelled { issue = error.localizedDescription } }
  }
}
