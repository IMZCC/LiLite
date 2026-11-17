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
        Picker("视频", selection: cellular ? $draft.cellVideo : $draft.wifiVideo) {
          ForEach(NetworkMediaRules.videoIDs, id: \.self) {
            Text($0 == 0 ? "自动" : StreamQuality.name($0)).tag($0)
          }
        }
        Picker("音质", selection: cellular ? $draft.cellAudio : $draft.wifiAudio) {
          ForEach(NetworkMediaRules.audioIDs, id: \.self) {
            Text(PlaybackOption.audioName($0)).tag($0)
          }
        }.settingAnchor("MediaProfilePanel/音质")
        Picker("直播", selection: cellular ? $draft.cellLive : $draft.wifiLive) {
          ForEach(NetworkMediaRules.liveIDs, id: \.self) {
            Text(PlaybackOption.liveName($0)).tag($0)
          }
        }.settingAnchor("MediaProfilePanel/直播")
      }.settingAnchor("MediaProfilePanel/默认清晰度")
      Section("视频编码优先顺序") {
        if cellular {
          Toggle(
            "与 Wi-Fi 相同",
            isOn: Binding(
              get: { draft.cellCodecs == nil },
              set: { draft.cellCodecs = $0 ? nil : draft.wifiCodecs })).settingAnchor("MediaProfilePanel/与 Wi-Fi 相同")
        }
        if !cellular || draft.cellCodecs != nil {
          ForEach(codecs, id: \.self) { item in
            HStack {
              Text(PlaybackOption.familyLabel(item))
              Spacer()
              Menu {
                if let i = codecs.firstIndex(of: item) {
                  if i > 0 {
                    Button("上移") {
                      var a = codecs
                      a.swapAt(i, i - 1)
                      update(a)
                    }
                  }
                  if i + 1 < codecs.count {
                    Button("下移") {
                      var a = codecs
                      a.swapAt(i, i + 1)
                      update(a)
                    }
                  }
                  if codecs.count > 1 {
                    Button("移除", role: .destructive) { update(codecs.filter { $0 != item }) }
                  }
                }
              } label: {
                Image(systemName: "ellipsis.circle").accessibilityLabel("调整 " + item)
              }
            }
          }
          let missing = NetworkMediaRules.families.filter { !codecs.contains($0) }
          if !missing.isEmpty {
            Menu("添加编码") {
              ForEach(missing, id: \.self) { c in
                Button(PlaybackOption.familyLabel(c)) { update(codecs + [c]) }
              }
            }.settingAnchor("MediaProfilePanel/添加编码")
          }
        }
      }.settingAnchor("MediaProfilePanel/视频编码优先顺序")
      if let issue { Text(issue) }
    }.navigationTitle(cellular ? "蜂窝网络" : "Wi-Fi 与有线网络")
      .toolbar {
        Button("保存") {
          do {
            try draft.save()
            dismiss()
          } catch { issue = error.localizedDescription }
        }
      }
  }
}
