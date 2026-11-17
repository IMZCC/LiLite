import SwiftUI

struct AppLinkPage: View {
  static let returnHome = Notification.Name("pili.routes.returnHome")
  let page: AppLibraryPage
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    switch page {
    case .root: Color.clear.task { NotificationCenter.default.post(name: Self.returnHome, object: nil) }
    case .history:
      if let uid = accounts.state.owner(.history) { ProfileFullHistory(uid: uid).id(uid) }
      else { ContentUnavailableView("观看历史已关闭或未登录", systemImage: "clock") }
    case .liveDirectory: LiveDirectory(area: nil, child: nil)
    case .ranking: Rankings()
    case .downloads: DownloadsView()
    case .login: QRLoginView()
    }
  }
}
struct FavoriteTabDestination: View {
  let tab: String
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    if let uid = accounts.state.active {
      FavoriteHub(uid: uid, initial: tab).id(uid + ":" + tab)
    } else {
      ContentUnavailableView {
        Label("登录后查看收藏", systemImage: "star")
      } actions: { NavigationLink("登录") { QRLoginView() } }
    }
  }
}
