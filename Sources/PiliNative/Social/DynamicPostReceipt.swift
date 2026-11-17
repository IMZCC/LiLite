import SwiftUI

struct DynamicPostReceipt: Identifiable {
  let id = UUID()
  let serverID: String?, uid: String
  let scheduled: Date?, privateOnly: Bool, repost: Bool
  var comment: String? = nil
  var verify = false
}
struct DynamicPostResult: View {
  let result: DynamicPostReceipt
  @Environment(\.dismiss) private var dismiss
  @State private var check: VisibilityRequest?
  var body: some View {
    PiliNavigationStack {
      Form {
        Label(
          result.scheduled != nil
            ? "已提交定时发布" : result.serverID == nil ? "已提交发布" : result.repost ? "转发成功" : "发布成功",
          systemImage: "checkmark.circle.fill"
        )
        .foregroundStyle(.green)
        if let date = result.scheduled { LabeledContent("预计发布时间", value: date.formatted()) }
        if result.privateOnly { LabeledContent("可见范围", value: "仅自己可见") }
        if let id = result.serverID {
          LabeledContent("动态编号") { Text(id).textSelection(.enabled) }
          if result.scheduled == nil {
            NavigationLink("查看动态") {
              DynamicDetail(id: id, privateOwner: result.privateOnly ? result.uid : nil)
            }.piliTapFeedback()
          }
        }
        if let comment = result.comment { Text(comment) }
        if let id = result.serverID, result.scheduled == nil && !result.privateOnly {
          Button("检查公开可见性") { check = .init(.moment(id), user: result.uid) }
        }
      }.navigationTitle("发布结果").toolbar { Button("完成") { dismiss() } }
    }.onAppear {
      if result.verify, let id = result.serverID, !result.privateOnly, result.scheduled == nil {
        check = .init(.moment(id), user: result.uid, after: 5)
      }
    }.piliSheet(item: $check) { VisibilityPanel(request: $0) }
  }
}
