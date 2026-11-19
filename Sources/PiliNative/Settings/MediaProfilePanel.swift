import SwiftUI

struct MediaProfilePanel: View {
  let cellular: Bool
  @State private var draft = NetworkMediaRules.current()
  @State private var issue: String?
  @Environment(\.dismiss) private var dismiss
  private var codecs: [String] { draft.codecOrder(cellular: cellular) }
  private func update(_ order: [String]) {
    if cellular { draft.cellCodecs = order } else { draft.wifiCodecs = order }
  }
  var body: some View {
    Form {
      Section("默认清晰度") {
        Picker(selection: cellular ? $draft.cellVideo : $draft.wifiVideo) {
          ForEach(NetworkMediaRules.videoIDs, id: \.self) {
            Text($0 == 0 ? "自动" : StreamQuality.name($0)).tag($0)
          }
        } label: { SettingsRowLabel(title: "视频", symbol: "play.rectangle", color: .blue) }
        Picker(selection: cellular ? $draft.cellAudio : $draft.wifiAudio) {
          ForEach(NetworkMediaRules.audioIDs, id: \.self) {
            Text(PlaybackOption.audioName($0)).tag($0)
          }
        } label: { SettingsRowLabel(title: "音质", symbol: "waveform", color: .orange) }
          .settingAnchor("MediaProfilePanel/音质")
        Picker(selection: cellular ? $draft.cellLive : $draft.wifiLive) {
          ForEach(NetworkMediaRules.liveIDs, id: \.self) {
            Text(PlaybackOption.liveName($0)).tag($0)
          }
        } label: { SettingsRowLabel(title: "直播", symbol: "dot.radiowaves.left.and.right", color: .pink) }
          .settingAnchor("MediaProfilePanel/直播")
      }.settingAnchor("MediaProfilePanel/默认清晰度")
      Section {
        if cellular {
          SettingToggle(
            title: "与 Wi-Fi 相同", symbol: "wifi", color: .blue,
            isOn: Binding(
              get: { draft.cellCodecs == nil },
              set: { draft.cellCodecs = $0 ? nil : draft.wifiCodecs })).settingAnchor("MediaProfilePanel/与 Wi-Fi 相同")
        }
        if !cellular || draft.cellCodecs != nil {
          ForEach(Array(codecs.enumerated()), id: \.element) { index, item in
            HStack(spacing: 12) {
              Text("\(index + 1)").font(.footnote.weight(.bold).monospacedDigit()).foregroundStyle(.white)
                .frame(width: 22, height: 22).iconGradient(.accentColor)
              Text(PlaybackOption.familyLabel(item))
            }
            .accessibilityLabel("第\(index + 1)位 " + PlaybackOption.familyLabel(item))
          }
          .onMove { from, to in
            var a = codecs
            a.move(fromOffsets: from, toOffset: to)
            update(a)
          }
          .onDelete { offsets in
            guard codecs.count - offsets.count >= 1 else { return }
            var a = codecs
            a.remove(atOffsets: offsets)
            update(a)
          }
          .deleteDisabled(codecs.count <= 1)
          let missing = NetworkMediaRules.families.filter { !codecs.contains($0) }
          if !missing.isEmpty {
            Menu {
              ForEach(missing, id: \.self) { c in
                Button(PlaybackOption.familyLabel(c)) { update(codecs + [c]) }
              }
            } label: {
              Label("添加编码", systemImage: "plus.circle.fill")
            }.settingAnchor("MediaProfilePanel/添加编码")
          }
        }
      } header: {
        Text("视频编码优先顺序")
      } footer: {
        Text("拖动排序，靠前的编码优先使用")
      }
      .settingAnchor("MediaProfilePanel/视频编码优先顺序")
      if let issue {
        Section { Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
      }
    }
    .environment(\.editMode, .constant(.active))
    .navigationTitle(cellular ? "蜂窝网络" : "Wi-Fi 与有线网络").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            do {
              try draft.save()
              dismiss()
            } catch { issue = error.localizedDescription }
          }
        }
      }
  }
}
