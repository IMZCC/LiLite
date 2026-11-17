import SwiftUI

struct APIProxyPanel: View {
  @State private var draft = APIProxy.current()
  @State private var message: String?
  @State private var failed = false
  var body: some View {
    Form {
      Section {
        SettingToggle(title: "使用 HTTP 代理", symbol: "network.badge.shield.half.filled", color: .blue,
          isOn: $draft.enabled).settingAnchor("APIProxyPanel/使用 HTTP 代理")
      } footer: {
        Text("用于哔哩哔哩接口和图片。关闭后使用系统网络设置")
      }
      Section {
        LabeledContent("主机") {
          TextField("主机名或 IP 地址", text: $draft.host).multilineTextAlignment(.trailing)
            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
        }
        LabeledContent("端口") {
          TextField("端口", text: $draft.port).multilineTextAlignment(.trailing).keyboardType(.numberPad)
            .monospacedDigit()
        }
      } header: {
        Text("代理服务器")
      } footer: {
        if let message { Text(message).foregroundStyle(failed ? .red : .secondary) }
      }
      .disabled(!draft.enabled)
    }
    .navigationTitle("接口代理").navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("保存") {
          do {
            try draft.save()
            draft = APIProxy.current()
            message = "已保存"; failed = false
          } catch { message = error.localizedDescription; failed = true }
        }
      }
    }
  }
}
