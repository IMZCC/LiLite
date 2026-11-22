import SwiftUI

struct HighQualityPlaybackSettings: View {
  @AppStorage(HighQualityPlayback.enabledKey) private var enabled = false
  @AppStorage(HighQualityPlayback.serverKey) private var server = ""
  @AppStorage(HighQualityPlayback.qualityKey) private var quality = 116
  @AppStorage(HighQualityPlayback.alwaysAcceptKey) private var alwaysAccept = true
  @AppStorage(HighQualityPlayback.desktopUAKey) private var desktopUA = true
  @State private var account = "读取中…"

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $enabled) {
          SettingsRowLabel(title: "高画质播放（实验性）", symbol: "sparkles.rectangle.stack.fill", color: .purple)
        }.settingAnchor("HighQualityPlaybackSettings/高画质播放")
        NavigationLink {
          SettingTextPage(
            title: "高画质服务地址",
            footer: "填写自建或信任的解析服务根地址，例如 https://example.com。启用后会把 SESSDATA、bili_jct 等登录凭证发送到该地址，请勿使用来路不明的服务。",
            text: $server, monospaced: true)
        } label: {
          HStack {
            SettingsRowLabel(title: "服务地址", symbol: "cloud.fill", color: .blue)
            Spacer(minLength: 8)
            Text(server.isEmpty ? "未配置" : server)
              .foregroundStyle(server.isEmpty ? .secondary : .secondary)
              .lineLimit(1).truncationMode(.middle)
          }
        }.settingAnchor("HighQualityPlaybackSettings/服务地址")
        Picker(selection: $quality) {
          ForEach(HighQualityPlayback.qualityOptions, id: \.self) { value in
            Text(HighQualityPlayback.qualityDescription(value)).tag(value)
          }
        } label: {
          SettingsRowLabel(title: "目标画质", symbol: "video.fill", color: .indigo)
        }.settingAnchor("HighQualityPlaybackSettings/目标画质")
        Toggle(isOn: $alwaysAccept) {
          SettingsRowLabel(title: "始终采用服务端流", symbol: "arrow.triangle.swap", color: .teal)
        }.settingAnchor("HighQualityPlaybackSettings/始终采用服务端流")
        Toggle(isOn: $desktopUA) {
          SettingsRowLabel(title: "远端 UA 使用桌面 Chrome", symbol: "safari.fill", color: .orange)
        }.settingAnchor("HighQualityPlaybackSettings/远端 UA")
      } header: {
        Text("高画质解析")
      } footer: {
        Text("非大会员请求 1080P 以上画质时，由服务端返回未降档的播放地址。仅对点播生效，下载与缓存不会使用该服务。")
      }

      Section {
        LabeledContent("最近结果") {
          Text(HighQualityPlayback.status).multilineTextAlignment(.trailing)
        }.settingAnchor("HighQualityPlaybackSettings/请求状态")
        LabeledContent("所用账号", value: account)
          .settingAnchor("HighQualityPlaybackSettings/所用账号")
        NavigationLink("最近一次请求与响应") {
          HighQualityPlaybackDiagnostics()
        }.settingAnchor("HighQualityPlaybackSettings/诊断")
      } header: {
        Text("状态")
      }

      if !enabled {
        Section {
          Text("开启“高画质播放”后生效。")
            .font(.footnote).foregroundStyle(.secondary)
        }
      }
    }
    .navigationTitle("高画质解析设置")
    .task(id: enabled) {
      account = await HighQualityPlayback.accountDescription()
    }
  }
}

struct HighQualityPlaybackDiagnostics: View {
  private var text: String {
    [
      HighQualityPlayback.lastAttempts,
      HighQualityPlayback.lastRequest,
      HighQualityPlayback.lastRawResponse,
    ].filter { !$0.isEmpty }.joined(separator: "\n\n")
  }
  var body: some View {
    ScrollView {
      Text(text.isEmpty ? "尚未发起请求" : text)
        .font(.footnote.monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
    .navigationTitle("高画质诊断")
    .navigationBarTitleDisplayMode(.inline)
  }
}
