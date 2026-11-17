import SwiftUI

struct APIProxyPanel: View {
  @State private var draft = APIProxy.current()
  @State private var message: String?
  var body: some View {
    Form {
      Section {
        Toggle("使用 HTTP 代理", isOn: $draft.enabled).settingAnchor("APIProxyPanel/使用 HTTP 代理")
        TextField("主机名或 IP 地址", text: $draft.host).textInputAutocapitalization(.never)
          .autocorrectionDisabled().keyboardType(.URL)
        TextField("端口", text: $draft.port).keyboardType(.numberPad)
      } footer: {
        Text("用于哔哩哔哩接口和图片。关闭后使用系统网络设置")
      }
      Button("保存") {
        do {
          try draft.save()
          draft = APIProxy.current()
          message = "已保存"
        } catch { message = error.localizedDescription }
      }
      if let message { Text(message).foregroundStyle(.secondary) }
    }.navigationTitle("接口代理")
  }
}
