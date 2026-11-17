import SwiftUI

struct DanmakuStylePanel: View {
  @State private var s = DanmakuStyle.decode(
    UserDefaults.standard.data(forKey: DanmakuStyle.key) ?? Data())
  @State private var normal = UserDefaults.standard.object(forKey: "dm.fontSize") as? Double ?? 15
  @State private var full = UserDefaults.standard.object(forKey: "dm.fullFontSize") as? Double ?? 18
  @State private var opacity = UserDefaults.standard.object(forKey: "dm.opacity") as? Double ?? 1
  @State private var area = UserDefaults.standard.object(forKey: "dm.area") as? Double ?? 0.5
  @State private var issue: String?
  @Environment(\.dismiss) private var dismiss
  private func count(_ text: String) -> String {
    let n = text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    return n == 0 ? "未设置" : "\(n) 条"
  }
  /// Live sample of the current size, weight, stroke and opacity over a dark frame.
  private var preview: some View {
    let weights: [Font.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
    let font = Font.system(size: normal, weight: weights[min(8, max(0, s.fontWeight - 1))])
    func line(_ text: String, _ color: Color) -> some View {
      Text(text).font(font).foregroundStyle(color)
        .shadow(color: .black.opacity(s.stroke > 0 ? 0.9 : 0), radius: s.stroke / 2)
        .shadow(color: .black.opacity(s.stroke > 0 ? 0.9 : 0), radius: s.stroke / 2)
    }
    return ZStack(alignment: .topLeading) {
      LinearGradient(colors: [Color(white: 0.3), Color(white: 0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
      VStack(alignment: .leading, spacing: normal * (s.lineHeight - 1) + 4) {
        line("前方高能预警！", .white).padding(.leading, 40)
        line("这个画面太好看了", s.monochrome ? .white : .yellow).padding(.leading, 120)
        line("哈哈哈哈哈", .white).padding(.leading, 12)
      }
      .opacity(opacity)
      .padding(.top, 14)
    }
    .frame(height: 140)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .animation(.snappy(duration: 0.2), value: [normal, opacity, s.stroke, s.lineHeight, Double(s.fontWeight)])
    .accessibilityHidden(true)
  }
  var body: some View {
    Form {
      Section {
        preview
          .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
      } footer: {
        Text("修改后点右上角“保存”生效。")
      }
      Section("显示") {
        MediaTextScaleControl(title: "普通字号", points: $normal)
        MediaTextScaleControl(title: "全屏字号", points: $full)
        SettingSlider(title: "不透明度", value: $opacity, range: 0...1).settingAnchor("DanmakuStylePanel/不透明度")
        SettingSlider(title: "显示区域", value: $area, range: 0.1...1, step: 0.1).settingAnchor("DanmakuStylePanel/显示区域")
        SettingStepper(title: "字重", value: $s.fontWeight.asDouble, range: 1...9) { "\(Int($0))" }.settingAnchor("DanmakuStylePanel/字重")
        SettingStepper(title: "描边", value: $s.stroke, range: 0...5, step: 0.5).settingAnchor("DanmakuStylePanel/描边")
        SettingStepper(title: "行高", value: $s.lineHeight, range: 0.8...3, step: 0.1) { $0.formatted(.number.precision(.fractionLength(1))) }.settingAnchor("DanmakuStylePanel/行高")
      }
      Section("运动") {
        SettingStepper(title: "滚动时长", value: $s.duration, range: 1...50, step: 0.5) { $0.formatted() + " 秒" }.settingAnchor("DanmakuStylePanel/滚动时长")
        SettingStepper(title: "固定时长", value: $s.staticDuration, range: 1...50, step: 0.5) { $0.formatted() + " 秒" }.settingAnchor("DanmakuStylePanel/固定时长")
        Toggle("滚动弹幕等速移动", isOn: $s.fixedVelocity.withTouchFeedback).settingAnchor("DanmakuStylePanel/滚动弹幕等速移动")
        Toggle("固定弹幕改为滚动", isOn: $s.convertFixed.withTouchFeedback).settingAnchor("DanmakuStylePanel/固定弹幕改为滚动")
        Toggle("允许密集弹幕重叠", isOn: $s.dense.withTouchFeedback).settingAnchor("DanmakuStylePanel/允许密集弹幕重叠")
      }
      Section("颜色") {
        Toggle("普通弹幕显示为白色", isOn: $s.monochrome.withTouchFeedback).settingAnchor("DanmakuStylePanel/普通弹幕显示为白色")
        Toggle("显示会员渐变色", isOn: $s.showVIP).settingAnchor("DanmakuStylePanel/显示会员渐变色")
      }
      Section {
        Toggle("屏蔽滚动弹幕", isOn: $s.hideScroll.withTouchFeedback).settingAnchor("DanmakuStylePanel/屏蔽滚动弹幕")
        Toggle("屏蔽顶部弹幕", isOn: $s.hideTop.withTouchFeedback).settingAnchor("DanmakuStylePanel/屏蔽顶部弹幕")
        Toggle("屏蔽底部弹幕", isOn: $s.hideBottom.withTouchFeedback).settingAnchor("DanmakuStylePanel/屏蔽底部弹幕")
        Toggle("屏蔽特殊弹幕", isOn: $s.hideSpecial.withTouchFeedback).settingAnchor("DanmakuStylePanel/屏蔽特殊弹幕")
        Toggle("合并重复弹幕", isOn: $s.merge).settingAnchor("DanmakuStylePanel/合并重复弹幕")
        SettingStepper(title: "最低权重", value: $s.minimumWeight.asDouble, range: 0...11) { "\(Int($0))" }.settingAnchor("DanmakuStylePanel/最低权重")
      } header: {
        Text("过滤")
      } footer: {
        Text("权重低于设定值的弹幕不显示，数值越高过滤越多。")
      }.settingAnchor("DanmakuStylePanel/屏蔽类型")
      Section("屏蔽规则") {
        NavigationLink {
          SettingTextPage(title: "屏蔽正则", footer: "每行一条正则表达式，弹幕内容匹配任一条时不显示。", text: $s.expressions, monospaced: true)
        } label: {
          LabeledContent("屏蔽正则", value: count(s.expressions))
        }.settingAnchor("DanmakuStylePanel/屏蔽正则 · 每行一条")
        NavigationLink {
          SettingTextPage(title: "屏蔽发送者", footer: "每行一个发送者标识（弹幕的用户哈希），来自这些用户的弹幕不显示。", text: $s.senders, monospaced: true)
        } label: {
          LabeledContent("屏蔽发送者", value: count(s.senders))
        }.settingAnchor("DanmakuStylePanel/屏蔽发送者 · 每行一个标识")
        NavigationLink("账号屏蔽规则") { AccountBulletRulePanel() }.settingAnchor("DanmakuStylePanel/账号屏蔽规则")
      }
      if let issue {
        Text(issue).font(.footnote).foregroundStyle(.red)
      }
    }.navigationTitle("弹幕样式与过滤").toolbar {
      Button("保存") {
        do {
          try s.save()
          let defaults = UserDefaults.standard
          for (key, value) in [("dm.fontSize", normal), ("dm.fullFontSize", full), ("dm.opacity", opacity), ("dm.area", area)] {
            defaults.set(value, forKey: key)
          }
          dismiss()
        } catch { issue = error.localizedDescription }
      }
    }
  }
}
