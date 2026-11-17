import SwiftUI

struct LiveCDNSettings: View {
  @AppStorage("live.cdn") private var saved: String?
  @State private var draft = ""
  @State private var issue: String?
  var body: some View {
    Form {
      Section {
        TextField("HTTPS 地址或主机名", text: $draft).settingAnchor("LiveCDNSettings/HTTPS 地址或主机名").keyboardType(.URL).autocorrectionDisabled()
          .textInputAutocapitalization(.never)
        if let issue { Text(issue).foregroundStyle(.secondary) }
        Button("保存") {
          let input = draft.trimmingCharacters(in: .whitespacesAndNewlines)
          if input.isEmpty {
            saved = nil
            draft = ""
            issue = nil
          } else if let origin = LiveCDNOrigin(input) {
            saved = origin.base.absoluteString
            draft = origin.base.absoluteString
            issue = nil
          } else {
            issue = "请输入 HTTPS 地址或主机名，不含账号、密码或查询参数"
          }
        }
        if saved != nil {
          Button("使用直播间默认线路") {
            saved = nil
            draft = ""
            issue = nil
          }.settingAnchor("LiveCDNSettings/使用直播间默认线路")
        }
      } header: {
        Text("直播 CDN")
      } footer: {
        Text("留空使用直播间提供的线路。自定义地址会收到本次直播的临时播放参数")
      }
    }.navigationTitle("直播 CDN").onAppear { draft = saved ?? "" }
  }
}
