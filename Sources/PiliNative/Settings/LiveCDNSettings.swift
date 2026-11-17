import SwiftUI

struct LiveCDNSettings: View {
  @AppStorage("live.cdn") private var saved: String?
  @State private var draft = ""
  @State private var issue: String?
  var body: some View {
    Form {
      Section {
        HStack {
          SettingsRowLabel(title: "当前线路", symbol: "dot.radiowaves.left.and.right", color: .pink)
          Spacer()
          Text(saved.flatMap { URL(string: $0)?.host } ?? "直播间默认").foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Section {
        TextField("HTTPS 地址或主机名", text: $draft).settingAnchor("LiveCDNSettings/HTTPS 地址或主机名").keyboardType(.URL).autocorrectionDisabled()
          .textInputAutocapitalization(.never)
          .onSubmit(apply)
        Button("保存", action: apply).disabled(draft.trimmingCharacters(in: .whitespaces) == (saved ?? ""))
      } header: {
        Text("自定义直播 CDN")
      } footer: {
        if let issue { Text(issue).foregroundStyle(.red) }
        else { Text("留空使用直播间提供的线路。自定义地址会收到本次直播的临时播放参数") }
      }
      if saved != nil {
        Section {
          Button("使用直播间默认线路") {
            saved = nil
            draft = ""
            issue = nil
          }.settingAnchor("LiveCDNSettings/使用直播间默认线路")
        }
      }
    }
    .navigationTitle("直播 CDN").navigationBarTitleDisplayMode(.inline)
    .onAppear { draft = saved ?? "" }
  }
  private func apply() {
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
}
