import SwiftUI

struct ArchivePlaybackOptions: View {
  @ObservedObject var model: PlayerModel
  @Environment(\.dismiss) private var dismiss
  @AppStorage(SpeedPresets.key) private var speedData = Data()
  var body: some View {
    PiliNavigationStack {
      Form {
        Section("画面") {
          Menu {
            ForEach(model.availableQualities, id: \.self) { quality in
              Button(StreamQuality.name(quality)) {
                Task { await model.changeQuality(quality, manualVideo: true) }
              }
            }
          } label: {
            LabeledContent("画质", value: model.switching ? "切换中" : StreamQuality.name(model.quality))
          }.disabled(model.availableQualities.isEmpty || model.switching)
          HStack {
            Text("视频线路")
            Spacer()
            PlayerLineButton(model: model)
          }
          HStack {
            Text("截取画面")
            Spacer()
            CaptureButton(player: model.engine).disabled(!model.ready)
          }
        }
        Section("音频与字幕") {
          SpokenTrackPicker(model: model)
          if !model.audioChoices.isEmpty {
            Menu("音质") {
              ForEach(model.audioChoices, id: \.self) { quality in
                Button(PlaybackOption.audioName(quality)) {
                  Task {
                    await model.changeQuality(
                      model.availableQualities.contains(model.quality)
                        ? model.quality : (model.availableQualities.first ?? 0), manualAudio: quality)
                  }
                }
              }
            }.disabled(model.switching)
          }
          SubtitlePicker(model: model)
          NavigationLink("播放器音量") { AudioLevelSettings() }
          LabeledContent("AirPlay") { OutputRouteButton().frame(width: 44, height: 36) }.disabled(!model.engine.supportsSystemVideo)
        }
        Section("播放") {
          NavigationLink("播放器内核") { PlaybackEngineSettings() }
          Menu {
            ForEach(SpeedPresets.decode(speedData), id: \.self) { rate in
              Button("\(rate.formatted())×") {
                model.rate = Float(rate)
                if model.playing { model.engine.rate = Float(rate) }
              }
            }
          } label: {
            LabeledContent("播放速度", value: Double(model.rate).formatted() + "×")
          }
          Menu("播放行为") {
            RepeatPicker(session: model.preferences)
            SessionPlaybackSettings(session: model.preferences)
          }
        }
      }.navigationTitle("播放选项").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
  }
}
