import SwiftUI

struct TimingSettings: View {
  @AppStorage(PresentationMode.modeKey) private var selected = PresentationMode.system.rawValue
  @AppStorage(PresentationMode.smoothingKey) private var factor = "0"
  @State private var editing = false
  @State private var draft = ""
  private func name(_ m: PresentationMode) -> String {
    switch m {
    case .system: "系统自动"
    case .audio: "跟随音频"
    case .resample: "屏幕同步 · 音频重采样"
    case .resampleDrop: "屏幕同步 · 重采样和增减画帧"
    case .resampleFree: "屏幕同步 · 仅重采样"
    case .tempo: "屏幕同步 · 保持音调"
    case .videoDrop: "屏幕同步 · 增减画帧"
    case .audioDrop: "屏幕同步 · 增减音频块"
    case .displayFree: "屏幕同步 · 音画独立"
    case .free: "音画各自计时"
    }
  }
  var body: some View {
    Picker("音画同步", selection: $selected) {
      ForEach(PresentationMode.allCases, id: \.self) { m in Text(name(m)).tag(m.rawValue) }
    }.settingAnchor("PlayerPreferencePanel/音画同步")
    Button {
      draft = factor
      editing = true
    } label: {
      HStack {
        Text("音频时钟平滑")
        Spacer()
        Text(factor == "0" ? "关闭" : factor).foregroundStyle(.secondary)
      }
    }.settingAnchor("PlayerPreferencePanel/音频时钟平滑")
    .alert("音频时钟平滑", isPresented: $editing) {
      TextField("0–10000", text: $draft).keyboardType(.numberPad)
      Button("取消", role: .cancel) {}
      Button("保存") { if let n = PresentationMode.validSmoothing(draft) { factor = String(n) } }
        .disabled(PresentationMode.validSmoothing(draft) == nil)
    } message: {
      Text("跟随音频时生效，0 为关闭")
    }
  }
}
