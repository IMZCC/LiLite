import SwiftUI

struct PlaybackEntryOptions: View {
  @AppStorage(InterfaceInteraction.preinitialize) private var early = false
  @AppStorage(InterfaceInteraction.pauseWhenBackground) private var pause = false
  var body: some View {
    Toggle(isOn: $early) {
      Text("提前载入播放器")
      Text("进入详情页前先准备播放器，起播更快但更耗流量").font(.caption).foregroundStyle(.secondary)
    }.settingAnchor("PlayerPreferencePanel/提前载入播放器")
    Toggle(isOn: $pause) {
      Text("切到后台时暂停视频")
      Text("返回时继续播放，画中画和后台收听除外").font(.caption).foregroundStyle(.secondary)
    }.settingAnchor("PlayerPreferencePanel/切到后台时暂停视频")
  }
}
struct InteractionScaleOptions: View {
  @AppStorage(InterfaceInteraction.horizontal) private var threshold = 24.0
  @AppStorage(InterfaceInteraction.displacement) private var displacement = 20.0
  @AppStorage(InterfaceInteraction.scale) private var scale = 1.0
  @State private var proposed = 1.0
  var body: some View {
    Form {
      Section {
        SettingSlider(title: "比例", value: $proposed, range: 0.5...2, step: 0.05)
          .settingAnchor("InteractionScaleOptions/比例")
        Button("应用缩放") { withAnimation { scale = proposed } }
          .frame(maxWidth: .infinity)
          .disabled(abs(proposed - scale) < 0.001)
          .settingAnchor("InteractionScaleOptions/应用缩放")
      } header: {
        Text("界面缩放")
      } footer: {
        Text("缩放整个界面的元素大小，点“应用缩放”后生效。")
      }.settingAnchor("InteractionScaleOptions/界面缩放")
      Section {
        SettingSlider(title: "起始距离", value: $threshold, range: 0...200, step: 1) { $0.formatted() + " 点" }
          .settingAnchor("InteractionScaleOptions/起始距离")
      } header: {
        Text("横向滑动")
      } footer: {
        Text("手指横向移动超过这个距离后才开始切换页面，数值越大越不容易误触。")
      }.settingAnchor("InteractionScaleOptions/横向滑动")
      Section {
        SettingSlider(title: "指示器高度", value: $displacement, range: 10...100, step: 10) { $0.formatted() + " 点" }
          .settingAnchor("InteractionScaleOptions/指示器高度")
      } header: {
        Text("下拉刷新")
      }.settingAnchor("InteractionScaleOptions/下拉刷新")
      Section {
        Button("恢复默认", role: .destructive) {
          withAnimation {
            threshold = 24
            displacement = 20
            proposed = 1; scale = 1
          }
        }.frame(maxWidth: .infinity)
      }
    }.navigationTitle("界面与手势").onChange(of: scale, initial: true) { _, v in proposed = InterfaceInteraction.interfaceScale(v) }
  }
}
struct PlaybackCover: View {
  let title: String, url: URL?, enabled: Bool, play: () -> Void
  var body: some View {
    ZStack {
      Color.black
      if let url {
        SiteThumbnail(url: url) {
          $0.resizable().scaledToFit()
        } placeholder: {
          Color.clear
        }
      }
      Button(action: play) {
        Image(systemName: "play.circle.fill").font(.system(size: 52)).symbolRenderingMode(.palette)
          .foregroundStyle(.white, .black.opacity(0.65))
      }.buttonStyle(.plain).disabled(!enabled).accessibilityLabel("播放" + title)
    }.clipped()
  }
}
