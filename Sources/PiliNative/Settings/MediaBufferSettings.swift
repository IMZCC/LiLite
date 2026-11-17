import SwiftUI

struct MediaBufferSettings: View {
  @AppStorage(MediaBufferPolicy.vodKey) private var vod = 4.0
  @AppStorage(MediaBufferPolicy.liveKey) private var live = 0.0
  @State private var videoInput = ""
  @State private var liveInput = ""
  @State private var issue: String?
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    Form {
      Section {
        capacity("点播缓冲", symbol: "play.rectangle", color: .blue, text: $videoInput)
          .settingAnchor("MediaBufferSettings/点播缓冲（MB）")
      } footer: {
        Text("前向和后向分别使用此容量")
      }
      Section {
        capacity("直播缓冲", symbol: "dot.radiowaves.left.and.right", color: .pink, text: $liveInput)
          .settingAnchor("MediaBufferSettings/直播缓冲（MB）")
      } footer: {
        Text("填 0 跟随点播容量的两倍")
      }
      Section {
        Button("恢复默认") {
          videoInput = "4"
          liveInput = "0"
          issue = nil
        }
      } footer: {
        if let issue { Text(issue).foregroundStyle(.red) }
      }
    }
    .navigationTitle("缓冲容量").navigationBarTitleDisplayMode(.inline)
    .onAppear {
      videoInput = vod.formatted(.number.grouping(.never))
      liveInput = live.formatted(.number.grouping(.never))
    }
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("保存") {
          func parse(_ text: String) -> Double? {
            // NumberFormatter.number(from:) accepts trailing garbage; parse the entire field.
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
              .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
            guard let n = Double(value), n.isFinite, (0...MediaBufferPolicy.maxSetting).contains(n)
            else { return nil }
            return n
          }
          guard let v = parse(videoInput), let l = parse(liveInput) else {
            issue = "请输入 0 至 512 之间的容量"
            return
          }
          vod = v
          live = l
          dismiss()
        }
      }
    }
  }
  private func capacity(_ title: String, symbol: String, color: Color, text: Binding<String>) -> some View {
    HStack {
      SettingsRowLabel(title: title, symbol: symbol, color: color)
      Spacer(minLength: 12)
      TextField("0", text: text).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
        .monospacedDigit().frame(maxWidth: 90)
      Text("MB").foregroundStyle(.secondary)
    }
  }
}
