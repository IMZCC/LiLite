import SwiftUI

struct ConnectionSettings: View {
  @AppStorage(BiliServiceSession.key) private var negotiate = false
  @AppStorage("web.external") private var external = false
  @AppStorage("network.retryCount") private var count = 2
  @AppStorage("network.retryDelay") private var delay = 500
  @AppStorage(ServerCertificatePolicy.key) private var invalidCertificates = false
  var body: some View {
    Form {
      NavigationLink("接口代理") { APIProxyPanel() }.settingAnchor("ConnectionSettings/接口代理")
      Section("接口连接") {
        Toggle("允许无效证书", isOn: $invalidCertificates).settingAnchor("ConnectionSettings/允许无效证书")
        Picker("HTTP 协议", selection: $negotiate) {
          Text("HTTP/1.1").tag(false)
          Text("自动协商").tag(true)
        }.settingAnchor("ConnectionSettings/HTTP 协议")
      }.settingAnchor("ConnectionSettings/接口连接")
      NavigationLink("视频线路") { VODLineSettings() }.settingAnchor("ConnectionSettings/视频线路")
      NavigationLink("直播 CDN") { LiveCDNSettings() }.settingAnchor("ConnectionSettings/直播 CDN")
      Section { Toggle("网页链接默认用浏览器打开", isOn: $external).settingAnchor("ConnectionSettings/网页链接默认用浏览器打开") }
      Section {
        SettingStepper(title: "连接重试", value: $count.asDouble, range: 0...8) { $0 == 0 ? "关闭" : "\(Int($0)) 次" }
        SettingStepper(title: "重试间隔", value: $delay.asDouble, range: 0...1000, step: 100) { "\(Int($0)) 毫秒" }
          .settingAnchor("ConnectionSettings/重试间隔").disabled(count == 0)
      } footer: {
        Text("第 2 次重试等待两倍间隔，后续依次增加")
      }
    }.navigationTitle("网络连接")
  }
}
