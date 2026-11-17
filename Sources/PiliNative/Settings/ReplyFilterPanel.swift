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
      Section {
        SettingToggle(title: "评论关键词搜索", symbol: "magnifyingglass", color: .blue, isOn: $wordSearch)
          .settingAnchor("ReplyFilterPanel/评论关键词搜索")
      } footer: {
        Text("长按评论中的关键词可直接搜索")
      }
      Section("默认排序") {
        Picker(selection: $mainSort) {
          Text("最新").tag(0)
          Text("最热").tag(1)
        } label: {
          SettingsRowLabel(title: "主评论", symbol: "text.bubble", color: .orange)
        }.settingAnchor("ReplyFilterPanel/主评论")
        Picker(selection: $detailSort) {
          Text("最新").tag(0)
          Text("最热").tag(1)
        } label: {
          SettingsRowLabel(title: "楼中楼", symbol: "bubble.left.and.bubble.right", color: .orange)
        }.settingAnchor("ReplyFilterPanel/楼中楼")
      }.settingAnchor("ReplyFilterPanel/默认排序")
      Section {
        SettingToggle(title: "屏蔽带货评论", symbol: "cart.badge.minus", color: .red, isOn: $rules.goods)
          .settingAnchor("ReplyFilterPanel/屏蔽带货评论")
        SettingToggle(title: "屏蔽只包含 @ 的评论", symbol: "at", color: .red, isOn: $rules.mentionsOnly)
          .settingAnchor("ReplyFilterPanel/屏蔽只包含 @ 的评论")
        SettingToggle(title: "屏蔽复制视频简介的评论", symbol: "doc.on.doc", color: .red, isOn: $rules.duplicateIntro)
          .settingAnchor("ReplyFilterPanel/屏蔽复制视频简介的评论")
        HStack {
          SettingsRowLabel(title: "屏蔽提及人数", symbol: "person.2.slash", color: .red)
          Spacer(minLength: 12)
          TextField("屏蔽提及人数（留空关闭）", text: $number, prompt: Text("关闭"))
            .settingAnchor("ReplyFilterPanel/屏蔽提及人数（留空关闭）")
            .keyboardType(.numberPad).multilineTextAlignment(.trailing).monospacedDigit().frame(maxWidth: 80)
        }
      } header: {
        Text("评论过滤")
      } footer: {
        Text("@ 的人数达到设定值时隐藏该评论，留空关闭")
      }
      .settingAnchor("ReplyFilterPanel/评论过滤")
      Section {
        TextField("屏蔽关键词或正则表达式", text: $rules.pattern, axis: .vertical)
          .settingAnchor("ReplyFilterPanel/屏蔽关键词或正则表达式")
          .lineLimit(2...6).font(.callout.monospaced())
          .textInputAutocapitalization(.never).autocorrectionDisabled()
      } header: {
        Text("关键词屏蔽")
      } footer: {
        Text("支持正则表达式，例如 广告|推广")
      }
      Section {
        SettingToggle(title: "显示头像挂件和装扮卡", symbol: "sparkles", color: .pink, isOn: $decorate)
          .settingAnchor("ReplyFilterPanel/显示头像挂件和装扮卡")
        SettingToggle(title: "点按预览正文表情", symbol: "face.smiling", color: .yellow, isOn: $preview)
          .settingAnchor("ReplyFilterPanel/点按预览正文表情")
        SettingToggle(title: "视频详情默认显示评论", symbol: "rectangle.bottomhalf.inset.filled", color: .blue, isOn: $openFirst)
          .settingAnchor("ReplyFilterPanel/视频详情默认显示评论")
        SettingToggle(title: "显示番剧评论", symbol: "film", color: .purple, isOn: $episodeReplies)
          .settingAnchor("ReplyFilterPanel/显示番剧评论")
        SettingToggle(title: "从屏幕边缘滑动返回", symbol: "hand.draw", color: .teal, isOn: $slideDismiss)
          .settingAnchor("ReplyFilterPanel/从屏幕边缘滑动返回")
        SettingStepper(title: "折叠行数", value: $rules.lines.asDouble, range: 0...30,
          format: { $0 == 0 ? "不折叠" : "\(Int($0)) 行" })
          .settingAnchor("ReplyFilterPanel/折叠行数")
      } header: {
        Text("评论显示")
      } footer: {
        Text("折叠行数设为 0 可展示完整评论")
      }
      .settingAnchor("ReplyFilterPanel/评论显示")
      if let issue {
        Section { Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
      }
    }
    .navigationTitle("评论设置").navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
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
}
