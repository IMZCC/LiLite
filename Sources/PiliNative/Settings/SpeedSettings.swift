import SwiftUI

enum SpeedPresets {
  static let key = "player.speedList"
  static let defaults: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3]
  static func valid(_ n: Double) -> Bool { Float(n).isFinite && Float(n) > 0 }
  static func checked(_ v: [Double]) -> Bool {
    !v.isEmpty && v.contains(1) && v.allSatisfy(valid) && Set(v.map(Float.init)).count == v.count
  }
  static func decode(_ data: Data) -> [Double] {
    guard let v = try? JSONDecoder().decode([Double].self, from: data), checked(v) else {
      return defaults
    }
    return v.sorted()
  }
  static func current(_ d: UserDefaults) -> [Double] { decode(d.data(forKey: key) ?? Data()) }
}
struct SpeedSettings: View {
  @AppStorage(SpeedPresets.key) private var data = Data()
  @AppStorage("play.rate") private var normal = 1.0
  @AppStorage("player.holdSpeed") private var hold = 3.0
  @AppStorage("player.doubleSpeed") private var automatic = false
  @State private var adding = false
  @State private var draft = ""
  @State private var issue: String?
  private var values: [Double] {
    SpeedPresets.decode(data)
  }
  var body: some View {
    Form {
      Section {
        LabeledContent("默认倍速", value: normal.formatted() + "×")
        if !automatic { LabeledContent("默认长按倍速", value: hold.formatted() + "×") }
        Toggle("长按时使用当前倍速的两倍", isOn: $automatic).settingAnchor("SpeedSettings/长按时使用当前倍速的两倍")
      } footer: {
        Text("在下方列表点按某个倍速，可设为默认或长按倍速。")
      }
      Section("可选倍速") {
        ForEach(values, id: \.self) { speed in
          Menu {
            Button("设为默认倍速") { normal = speed }
            Button("设为长按倍速") { hold = speed }.disabled(automatic)
            Button("删除", role: .destructive) { save(values.filter { $0 != speed }) }.disabled(
              speed == 1 || speed == normal || speed == hold)
          } label: {
            HStack(spacing: 8) {
              Text(speed.formatted() + "×").font(.body.monospacedDigit()).foregroundStyle(.primary)
              Spacer()
              if speed == normal { tag("默认", .blue) }
              if !automatic && speed == hold { tag("长按", .orange) }
            }
          }
        }
        Button {
          draft = ""
          adding = true
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(.white, .green)
            Text("添加倍速").foregroundStyle(.primary)
          }
        }.settingAnchor("SpeedSettings/添加倍速")
      }.settingAnchor("SpeedSettings/可选倍速")
      if let issue { Text(issue).font(.footnote).foregroundStyle(.red) }
    }
    .animation(.snappy(duration: 0.25), value: values)
    .animation(.snappy(duration: 0.25), value: automatic)
    .navigationTitle("播放倍速").toolbar{
      Button("重置列表"){UserDefaults.standard.removeObject(forKey:SpeedPresets.key);issue=nil}
    }.alert("添加倍速", isPresented: $adding) {
      TextField("例如 1.75", text: $draft).keyboardType(.decimalPad)
      Button("添加") {
        let v = Double(draft.replacingOccurrences(of: ",", with: "."))
        guard let v, SpeedPresets.valid(v) else {
          issue = "请输入有效的正数"
          return
        }
        guard !values.contains(where: { Float($0) == Float(v) }) else {
          issue = "该倍速已存在"
          return
        }
        save(values + [v])
      }
      Button("取消", role: .cancel) {}
    }
  }
  private func tag(_ text: String, _ color: Color) -> some View {
    Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
      .padding(.horizontal, 8).padding(.vertical, 3)
      .background(color.opacity(0.14), in: Capsule())
  }
  private func save(_ v: [Double]) {
    guard SpeedPresets.checked(v), let d = try? JSONEncoder().encode(v.sorted()) else { return }
    data = d
    issue = nil
  }
}
