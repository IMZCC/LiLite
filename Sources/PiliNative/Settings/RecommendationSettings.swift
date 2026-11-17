import SwiftUI

struct RecommendationSettings: View {
  @AppStorage("grid.recommendWidth") private var recWidth = 240.0
  @AppStorage("grid.cardWidth") private var cardWidth = 240.0
  @AppStorage("feed.hotEntrances") private var hotEntrances = false
  @AppStorage("feed.mobile") private var mobile = true
  @AppStorage("feed.keepPrevious") private var keep = true
  @AppStorage("feed.retainedTip") private var tip = true
  @State private var draft = RecommendationRules.current()
  @State private var issue: String?
  @State private var creator = ""
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    Form {
      Section("卡片最大列宽") {
        SettingStepper(title: "首页推荐", value: $recWidth, range: 150...500, step: 10) { "\(Int($0)) 点" }
        SettingStepper(title: "其他页面", value: $cardWidth, range: 150...500, step: 10) { "\(Int($0)) 点" }
      }.settingAnchor("RecommendationSettings/卡片最大列宽")
      Section("热门") { Toggle("显示榜单快捷入口", isOn: $hotEntrances).settingAnchor("RecommendationSettings/显示榜单快捷入口") }.settingAnchor("RecommendationSettings/热门")
      Section("推荐来源") { Toggle("使用移动端推荐", isOn: $mobile).settingAnchor("RecommendationSettings/使用移动端推荐") }.settingAnchor("RecommendationSettings/推荐来源")
      Section("下拉刷新") {
        Toggle("保留上次推荐", isOn: $keep).settingAnchor("RecommendationSettings/保留上次推荐")
        if keep { Toggle("标出上次刷新的位置", isOn: $tip).settingAnchor("RecommendationSettings/标出上次刷新的位置") }
      }.settingAnchor("RecommendationSettings/下拉刷新")
      Section("推荐内容") {
        LabeledContent("最短时长（秒）") {
          TextField("0", value: $draft.minimumSeconds, format: .number).keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
        }.settingAnchor("RecommendationSettings/最短时长（秒）")
        LabeledContent("最低播放量") {
          TextField("0", value: $draft.minimumViews, format: .number).keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
        }.settingAnchor("RecommendationSettings/最低播放量")
        SettingStepper(title: "最低点赞率", value: $draft.minimumLikePercent.asDouble, range: 0...100) { "\(Int($0))%" }.settingAnchor("RecommendationSettings/最低点赞率")
        TextField("屏蔽标题关键词或正则表达式", text: $draft.titlePattern).settingAnchor("RecommendationSettings/屏蔽标题关键词或正则表达式").textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Toggle("推荐中豁免已关注的 UP 主", isOn: $draft.exemptFollowed).settingAnchor("RecommendationSettings/推荐中豁免已关注的 UP 主")
        Toggle("同时筛选相关视频", isOn: $draft.filterRelated).settingAnchor("RecommendationSettings/同时筛选相关视频")
      }.settingAnchor("RecommendationSettings/推荐内容")
      Section("分区过滤") {
        TextField("屏蔽分区关键词或正则表达式", text: $draft.zonePattern).settingAnchor("RecommendationSettings/屏蔽分区关键词或正则表达式").textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      }.settingAnchor("RecommendationSettings/分区过滤")
      Section("本机屏蔽的 UP 主") {
        HStack {
          TextField("输入 UID", text: $creator).settingAnchor("RecommendationSettings/输入 UID").keyboardType(.numberPad)
          Button("添加") {
            if let id = Int64(creator), id > 0 {
              draft.blockedCreators.insert(id)
              creator = ""
            }
          }.disabled((Int64(creator) ?? 0) <= 0)
        }
        ForEach(draft.blockedCreators.sorted(), id: \.self) { id in
          HStack {
            Text(String(id))
            Spacer()
            Button("移除") { draft.blockedCreators.remove(id) }
          }
        }
      }.settingAnchor("RecommendationSettings/本机屏蔽的 UP 主")
      if let issue { Text(issue).foregroundStyle(.secondary) }
    }.navigationTitle("推荐过滤").toolbar {
      Button("保存") {
        do {
          try draft.save()
          dismiss()
        } catch { issue = error.localizedDescription }
      }
    }
  }
}
