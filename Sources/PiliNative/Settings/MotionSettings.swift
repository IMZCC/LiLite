import SwiftUI

struct MotionSettings: View {
  @AppStorage(PageMotion.key) private var motion = PageMotion.native.rawValue
  @State private var mode = 0
  @State private var spring = ScrollSpring.current()
  @State private var a = ""
  @State private var b = ""
  @State private var c = ""
  @State private var issue: String?
  @State private var shifted = false
  var body: some View {
    Form {
      Section("页面切换") {
        Picker(selection: $motion) {
          ForEach(PageMotion.allCases, id: \.rawValue) { item in Text(item.title).tag(item.rawValue) }
        } label: {
          SettingsRowLabel(title: "过渡效果", symbol: "rectangle.portrait.on.rectangle.portrait", color: .indigo)
        }.settingAnchor("MotionSettings/过渡效果")
        NavigationLink {
          ContentUnavailableView("页面切换预览", systemImage: "rectangle.portrait.on.rectangle.portrait",
            description: Text("返回时观察当前的过渡效果"))
            .navigationTitle("页面切换")
        } label: {
          SettingsRowLabel(title: "预览页面切换", symbol: "play.circle", color: .indigo)
        }.settingAnchor("MotionSettings/预览页面切换")
      }.settingAnchor("MotionSettings/页面切换")
      Section {
        Picker("参数", selection: $mode) {
          Text("物理参数").tag(0); Text("时长与弹性").tag(1)
        }.settingAnchor("MotionSettings/参数").pickerStyle(.segmented).listRowSeparator(.hidden)
        number(mode == 0 ? "质量" : "时长（秒）", $a)
        number(mode == 0 ? "刚度" : "弹性", $b)
        if mode == 0 { number("阻尼", $c) }
        Button("应用参数") {
          guard let x = Double(a), let y = Double(b),
            let choice = mode == 0 ? Double(c).flatMap({ ScrollSpring([x, y, $0]) }) : ScrollSpring(duration: x, bounce: y)
          else { issue = "请填写有效的回弹参数"; return }
          store(choice)
        }
        Button("恢复默认") { store(ScrollSpring(ScrollSpring.standard)!) }
      } header: {
        Text("滚动回弹")
      } footer: {
        if let issue { Text(issue).foregroundStyle(.red) }
      }
      .settingAnchor("MotionSettings/滚动回弹")
      Section {
        GeometryReader { g in
          Capsule().fill(.quaternary).frame(height: 6).frame(maxHeight: .infinity)
          Circle().fill(.tint).frame(width: 26, height: 26).shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            .offset(x: shifted ? max(0, g.size.width - 26) : 0).frame(maxHeight: .infinity)
        }
        .frame(height: 34).accessibilityHidden(true)
        Button("预览回弹") {
          withAnimation(.interpolatingSpring(mass: spring.mass, stiffness: spring.stiffness, damping: spring.damping, initialVelocity: 0)) { shifted.toggle() }
        }.settingAnchor("MotionSettings/预览回弹")
      }
    }
    .background(MotionProbe().frame(width: 0, height: 0))
    .navigationTitle("页面动画与回弹").navigationBarTitleDisplayMode(.inline)
    .onAppear { fields() }.onChange(of: mode) { _, _ in fields() }
  }
  private func number(_ label: String, _ value: Binding<String>) -> some View {
    LabeledContent(label) {
      TextField(label, text: value).multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation)
        .monospacedDigit()
    }
  }
  private func store(_ value: ScrollSpring) {
    spring = value; UserDefaults.standard.set(value.values, forKey: ScrollSpring.key)
    issue = nil; fields()
  }
  private func fields() {
    if mode == 0 { a = String(spring.mass); b = String(spring.stiffness); c = String(spring.damping) }
    else { a = String(spring.duration); b = String(spring.bounce) }
  }
}
