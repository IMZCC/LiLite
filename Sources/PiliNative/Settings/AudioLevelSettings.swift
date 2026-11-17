import SwiftUI

struct AudioLevelSettings: View {
  @AppStorage("audio.gainPercent") private var gain = 100.0
  @AppStorage("audio.normalization") private var normal = "0"
  @AppStorage("audio.fallbackNormalization") private var fallback = "0"
  var body: some View {
    Form {
      Section("播放器增益") {
        SettingSlider(title: "音量", value: $gain, range: 100...300, step: 5) { "\(Int($0))%" }.settingAnchor("AudioLevelSettings/音量")
        Button("恢复 100%") { withAnimation { gain = 100 } }.settingAnchor("AudioLevelSettings/恢复 100%").disabled(gain == 100)
      }.settingAnchor("AudioLevelSettings/播放器增益")
      Section("音量均衡") {
        NavigationLink {
          SoundPreset(title: "音量均衡", value: $normal)
        } label: { LabeledContent("均衡模式", value: SoundPreset.label(normal)) }.settingAnchor("AudioLevelSettings/均衡模式")
        if normal == "2" || normal.contains("loudnorm") {
          NavigationLink {
            SoundPreset(title: "无响度数据时", value: $fallback)
          } label: { LabeledContent("无响度数据时", value: SoundPreset.label(fallback)) }.settingAnchor("AudioLevelSettings/无响度数据时")
        }
      }.settingAnchor("AudioLevelSettings/音量均衡")
    }.navigationTitle("播放器音量")
  }
}

private struct SoundPreset: View {
  let title: String
  @Binding var value: String
  @State private var custom = ""
  @State private var issue: String?
  @Environment(\.dismiss) private var dismiss
  static func label(_ value: String) -> String {
    switch value { case "0": return "关闭"; case "1": return "动态均衡"; case "2": return "响度标准化"; default: return "自定义" }
  }
  var body: some View {
    Form {
      Section {
        ForEach(["0", "1", "2"], id: \.self) { choice in
          Button {
            value = choice; dismiss()
          } label: {
            HStack { Text(Self.label(choice)); Spacer(); if value == choice { Image(systemName: "checkmark") } }
          }
        }
      }
      Section("自定义滤镜") {
        TextField("loudnorm=I=-16:LRA=11:TP=-1.5", text: $custom, axis: .vertical)
          .autocorrectionDisabled().textInputAutocapitalization(.never)
        Button("应用") {
          let proposed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !proposed.isEmpty, AudioFilterChoice.valid(proposed) else { issue = "请检查滤镜名称和参数范围"; return }
          value = proposed; dismiss()
        }
        if let issue { Text(issue).foregroundStyle(.secondary) }
      }
    }.navigationTitle(title).onAppear { if !["0", "1", "2"].contains(value) { custom = value } }
  }
}
