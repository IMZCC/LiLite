import SwiftUI

private struct FocusedSettingKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
  fileprivate var focusedSetting: String? {
    get { self[FocusedSettingKey.self] }
    set { self[FocusedSettingKey.self] = newValue }
  }
}

private struct SettingFocusModifier: ViewModifier {
  let anchor: String
  @Environment(\.focusedSetting) private var selected
  @ViewBuilder func body(content: Content) -> some View {
    if selected != nil {
      content.id(anchor).listRowBackground(selected == anchor ? Color.accentColor.opacity(0.14) : nil)
    } else { content }
  }
}
extension View {
  func settingAnchor(_ key: String) -> some View { modifier(SettingFocusModifier(anchor: key)) }
}

struct NativeSettingsResults: View {
  let query: String
  var body: some View {
    let rows = SettingSearchRow.matches(query)
    if rows.isEmpty { ContentUnavailableView.search(text: query) }
    else {
      Section("设置搜索结果") {
        ForEach(rows) { item in
          let target = item.location()
          NavigationLink {
            ScrollViewReader { scroll in
              Self.destination(item)
                .environment(\.focusedSetting, target.anchor)
                .task(id: item.id) {
                  await Task.yield()
                  scroll.scrollTo(target.anchor, anchor: .center)
                  do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                  scroll.scrollTo(target.anchor, anchor: .center)
                }
            }
          } label: {
            VStack(alignment: .leading, spacing: 3) {
              Text(item.title)
              Text(target.hint.map { item.section + " · " + $0 } ?? item.section).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }
  @MainActor static func destination(_ item: SettingSearchRow) -> AnyView {
    switch item.screen {
    case "SettingsView": return AnyView(SettingsView(allowSplit:false))
    case "PlaybackOptionsView": return AnyView(PlaybackOptionsView())
    case "HighQualityPlaybackSettings": return AnyView(HighQualityPlaybackSettings())
    case "DecoderSettings": return AnyView(DecoderSettings())
    case "GallerySettings": return AnyView(GallerySettings())
    case "SuperChatSettings": return AnyView(SuperChatSettings())
    case "SponsorSettings": return AnyView(SponsorSettings())
    case "ViewportSettings": return AnyView(ViewportSettings())
    case "APIProxyPanel": return AnyView(APIProxyPanel())
    case "ArtworkCacheSettings": return AnyView(ArtworkCacheSettings())
    case "AudioLevelSettings": return AnyView(AudioLevelSettings())
    case "ConnectionSettings": return AnyView(ConnectionSettings())
    case "DanmakuStylePanel": return AnyView(DanmakuStylePanel())
    case "DeviceIdentityPanel": return AnyView(DeviceIdentityPanel())
    case "InteractionScaleOptions": return AnyView(InteractionScaleOptions())
    case "LiveCDNSettings": return AnyView(LiveCDNSettings())
    case "MediaBufferSettings": return AnyView(MediaBufferSettings())
    case "MediaProfilePanel": return AnyView(MediaProfilePanel(cellular: item.cellular == true))
    case "MotionSettings": return AnyView(MotionSettings())
    case "NavigationLayoutPanel": return AnyView(NavigationLayoutPanel())
    case "PlayerPreferencePanel": return AnyView(PlayerPreferencePanel())
    case "CaptionStylePanel": return AnyView(CaptionStylePanel())
    case "RecommendationSettings": return AnyView(RecommendationSettings())
    case "VersionPanel": return AnyView(VersionPanel())
    case "ReplyFilterPanel": return AnyView(ReplyFilterPanel())
    case "SpeedSettings": return AnyView(SpeedSettings())
    case "ThemePicker": return AnyView(ThemePicker())
    case "TypographyPanel": return AnyView(TypographyPanel())
    case "DisplayPanel": return AnyView(DisplayPanel())
    case "VODLineSettings": return AnyView(VODLineSettings())
    case "CommunityFilterPanel": return AnyView(CommunityFilterPanel())
    case "BadgePreferences": return AnyView(BadgePreferences())
    default: return AnyView(ContentUnavailableView("未找到设置", systemImage: "slider.horizontal.3"))
    }
  }
}
