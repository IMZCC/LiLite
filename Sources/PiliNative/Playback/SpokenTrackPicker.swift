import SwiftUI

struct SpokenTrackPicker: View {
  @ObservedObject var model: PlayerModel
  var body: some View {
    if !model.spokenTracks.isEmpty {
      Menu {
        Button("默认原声") { Task { await model.changeLanguage(nil) } }
        ForEach(model.spokenTracks) { track in
          Button {
            Task { await model.changeLanguage(track) }
          } label: {
            if model.spokenLanguage == track.id {
              Label(track.label, systemImage: "checkmark")
            } else {
              Text(track.label)
            }
          }
        }
      } label: {
        Label("配音语言", systemImage: "waveform.and.mic")
      }.disabled(model.switching)
    }
  }
}
