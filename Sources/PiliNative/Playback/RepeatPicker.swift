import SwiftUI

struct RepeatPicker: View {
  var session: PlayerSessionPreferences? = nil
  @AppStorage(VideoRepeat.key) private var mode = VideoRepeat.pause.rawValue
  var body: some View {
    let effective = Binding<Int>(
      get: { session?.repeatMode.rawValue ?? mode },
      set: { n in
        if let session { session.repeatMode = VideoRepeat(rawValue: n) ?? .pause } else { mode = n }
      })
    Picker(selection: effective) {
      ForEach(VideoRepeat.allCases) { Text($0.label).tag($0.rawValue) }
    } label: {
      Label("播放顺序", systemImage: "repeat")
    }
    .pickerStyle(.menu).accessibilityValue(
      VideoRepeat(rawValue: effective.wrappedValue)?.label ?? "播完暂停")
  }
}
struct StoryFinish: View {
  @ObservedObject var model: PlayerModel
  var body: some View {
    if model.storyEnded {
      ScrollView {
        VStack(spacing: 10) {
          if let error = model.storyError {
            Text(error)
            Button("重新载入剧情") { model.retryStory?() }.buttonStyle(.borderedProminent)
          } else if model.storyOptions.isEmpty { ProgressView() }
          else { Text("选择剧情走向").font(.headline) }
          ForEach(model.storyOptions) { choice in
            Button(choice.option ?? "继续") { model.chooseStory(choice) }.buttonStyle(
              .borderedProminent)
          }
        }.padding()
      }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.75))
        .foregroundStyle(.white)
    }
  }
}
