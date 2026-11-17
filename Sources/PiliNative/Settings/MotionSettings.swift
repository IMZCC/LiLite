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
        Picker("过渡效果", selection: $motion) {
          ForEach(PageMotion.allCases, id: \.rawValue) { item in Text(item.title).tag(item.rawValue) }
        }.settingAnchor("MotionSettings/过渡效果")
        NavigationLink("预览页面切换") { Text("预览").navigationTitle("页面切换") }.settingAnchor("MotionSettings/预览页面切换")
      }.settingAnchor("MotionSettings/页面切换")
      Section("滚动回弹") {
        Picker("参数", selection: $mode) {
          Text("物理参数").tag(0); Text("时长与弹性").tag(1)
        }.settingAnchor("MotionSettings/参数").pickerStyle(.segmented)
        number(mode == 0 ? "质量" : "时长（秒）", $a)
        number(mode == 0 ? "刚度" : "弹性", $b)
        if mode == 0 { number("阻尼", $c) }
        HStack {
          Button("应用") {
            guard let x = Double(a), let y = Double(b),
              let choice = mode == 0 ? Double(c).flatMap({ ScrollSpring([x, y, $0]) }) : ScrollSpring(duration: x, bounce: y)
            else { issue = "请填写有效的回弹参数"; return }
            store(choice)
          }
          Spacer()
          Button("恢复默认") { store(ScrollSpring(ScrollSpring.standard)!) }
        }
        if let issue { Text(issue).foregroundStyle(.secondary) }
        Button("预览回弹") {
          withAnimation(.interpolatingSpring(mass: spring.mass, stiffness: spring.stiffness, damping: spring.damping, initialVelocity: 0)) { shifted.toggle() }
        }.settingAnchor("MotionSettings/预览回弹")
        GeometryReader { g in
          Circle().fill(.tint).frame(width: 22, height: 22).offset(x: shifted ? max(0, g.size.width - 22) : 0)
        }.frame(height: 28).accessibilityHidden(true)
      }.settingAnchor("MotionSettings/滚动回弹")
    }.background(MotionProbe().frame(width: 0, height: 0)).navigationTitle("页面动画与回弹").onAppear { fields() }.onChange(of: mode) { _, _ in fields() }
  }
  private func number(_ label: String, _ value: Binding<String>) -> some View {
    LabeledContent(label) { TextField(label, text: value).multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation) }
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
