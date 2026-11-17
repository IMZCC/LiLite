import SwiftUI

struct ReplyFilterPanel: View {
  @AppStorage("appearance.decorate") private var decorate = true
  @AppStorage("emote.preview") private var preview = false
  @AppStorage("reply.wordSearch") private var wordSearch = false
  @AppStorage("reply.openFirst") private var openFirst = false
  @AppStorage("reply.mainSort") private var mainSort = 1
  @AppStorage("reply.detailSort") private var detailSort = 0
  @AppStorage("detail.episodeReplies") private var episodeReplies = true
  @AppStorage("reply.edgeDismiss") private var slideDismiss = true
  @State private var rules = ReplyFilterRules.current()
  @State private var number = ReplyFilterRules.current().threshold.map(String.init) ?? ""
  @State private var issue: String?
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    Form {
      Section { Toggle("评论关键词搜索", isOn: $wordSearch).settingAnchor("ReplyFilterPanel/评论关键词搜索") }
      Section("默认排序") {
        Picker("主评论", selection: $mainSort) {
          Text("最新").tag(0)
          Text("最热").tag(1)
        }.settingAnchor("ReplyFilterPanel/主评论")
        Picker("楼中楼", selection: $detailSort) {
          Text("最新").tag(0)
          Text("最热").tag(1)
        }.settingAnchor("ReplyFilterPanel/楼中楼")
      }.settingAnchor("ReplyFilterPanel/默认排序")
      Section("评论过滤") {
        Toggle("屏蔽带货评论", isOn: $rules.goods).settingAnchor("ReplyFilterPanel/屏蔽带货评论")
        Toggle("屏蔽只包含 @ 的评论", isOn: $rules.mentionsOnly).settingAnchor("ReplyFilterPanel/屏蔽只包含 @ 的评论")
        Toggle("屏蔽复制视频简介的评论", isOn: $rules.duplicateIntro).settingAnchor("ReplyFilterPanel/屏蔽复制视频简介的评论")
        TextField("屏蔽提及人数（留空关闭）", text: $number).settingAnchor("ReplyFilterPanel/屏蔽提及人数（留空关闭）").keyboardType(.numberPad)
        TextField("屏蔽关键词或正则表达式", text: $rules.pattern, axis: .vertical).settingAnchor("ReplyFilterPanel/屏蔽关键词或正则表达式").textInputAutocapitalization(
          .never
        ).autocorrectionDisabled()
      }.settingAnchor("ReplyFilterPanel/评论过滤")
      Section("评论显示") {
        Toggle("显示头像挂件和装扮卡", isOn: $decorate).settingAnchor("ReplyFilterPanel/显示头像挂件和装扮卡")
        Toggle("点按预览正文表情", isOn: $preview).settingAnchor("ReplyFilterPanel/点按预览正文表情")
        Toggle("视频详情默认显示评论", isOn: $openFirst).settingAnchor("ReplyFilterPanel/视频详情默认显示评论")
        Toggle("显示番剧评论", isOn: $episodeReplies).settingAnchor("ReplyFilterPanel/显示番剧评论")
        Toggle("从屏幕边缘滑动返回", isOn: $slideDismiss).settingAnchor("ReplyFilterPanel/从屏幕边缘滑动返回")
        TextField("折叠行数", value: $rules.lines, format: .number).settingAnchor("ReplyFilterPanel/折叠行数").keyboardType(.numberPad)
        Text("设为 0 可展示完整评论").foregroundStyle(.secondary)
      }.settingAnchor("ReplyFilterPanel/评论显示")
      if let issue { Text(issue) }
    }.navigationTitle("评论设置").toolbar {
      Button("保存") {
        do {
          if number.isEmpty {
            rules.threshold = nil
          } else if let n = Int(number), n >= 0 {
            rules.threshold = n > 0 ? n : nil
          } else {
            throw ServiceError("请输入有效的提及人数")
          }
          try rules.save()
          dismiss()
        } catch { issue = error.localizedDescription }
      }
    }
  }
}
