import SwiftUI

enum SettingsPane: String, Identifiable, CaseIterable {
  case general = "全部设置"
  case account = "账号与隐私"
  case recommendations = "推荐"
  case video = "画面与音轨"
  case play = "播放控制"
  case danmaku = "弹幕"
  case replies = "评论"
  case dynamics = "动态"
  case style = "外观和布局"
  case extra = "其他设置"
  case webdav = "WebDAV 备份"
  case about = "关于"
  var id: Self { self }
  var icon: String {
    switch self {
    case .general: "magnifyingglass"
    case .account: "person.crop.circle"
    case .recommendations: "star"
    case .video: "film"
    case .play: "play.rectangle"
    case .danmaku: "text.bubble"
    case .replies: "bubble.left"
    case .dynamics: "person.2"
    case .style: "paintbrush"
    case .extra: "slider.horizontal.3"
    case .webdav: "externaldrive"
    case .about: "info.circle"
    }
  }
}
struct SettingsWidePane<General: View>: View {
  @EnvironmentObject private var accounts: AccountContext
  @Binding var choice: SettingsPane
  @State private var search = ""
  let general: General
  var body: some View {
    HStack(spacing: 0) {
      List(SettingsPane.allCases) { row in
        Button {
          choice = row
        } label: {
          Label(row.rawValue, systemImage: row.icon).foregroundStyle(
            choice == row ? Color.accentColor : .primary)
        }
        .accessibilityAddTraits(row == choice ? .isSelected : [])
      }.listStyle(.sidebar).frame(minWidth: 176, idealWidth: 210, maxWidth: 250)
      Divider()
      PiliNavigationStack {
        if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          details.id(choice)
        } else {
          List { NativeSettingsResults(query: search) }.navigationTitle("搜索设置")
        }
      }.id(choice).frame(maxWidth: .infinity)
    }.navigationTitle("设置").searchable(text: $search, prompt: "搜索全部设置")
  }
  @ViewBuilder private var details: some View {
    switch choice {
    case .general: general
    case .account:
      Form {
        NavigationLink("切换与退出账号") { SettingsAccountActions() }
        NavigationLink("客户端设备标识") { DeviceIdentityPanel() }
        if let uid = accounts.state.active {
          NavigationLink("黑名单") { BlacklistView(uid: uid) }
          NavigationLink("空间隐私") { SpacePrivacy(uid: uid) }
        }
      }.navigationTitle(choice.rawValue)
    case .recommendations: RecommendationSettings()
    case .video: PlaybackOptionsView()
    case .play: PlayerPreferencePanel()
    case .danmaku: DanmakuStylePanel()
    case .replies: ReplyFilterPanel()
    case .dynamics: CommunityFilterPanel()
    case .style:
      Form {
        NavigationLink("导航布局") { NavigationLayoutPanel() }
        NavigationLink("字体与字号") { TypographyPanel() }
        NavigationLink("主题颜色") { ThemePicker() }
        NavigationLink("页面动画与回弹") { MotionSettings() }
        NavigationLink("界面与手势") { InteractionScaleOptions() }
        NightSettings()
      }.navigationTitle(choice.rawValue)
    case .extra:
      Form {
        NavigationLink("未读提醒") { BadgePreferences() }
        NavigationLink("网络连接") { ConnectionSettings() }
        NavigationLink("图片缓存") { ArtworkCacheSettings() }
        NavigationLink("诊断日志") { DiagnosticView() }
        NavigationLink("版本与更新") { VersionPanel() }
      }.navigationTitle(choice.rawValue)
    case .webdav: WebBackup()
    case .about: AboutPanel()
    }
  }
}
