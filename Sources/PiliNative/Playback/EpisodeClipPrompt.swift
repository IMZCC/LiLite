import SwiftUI

struct EpisodeClipPrompt:View{
  @ObservedObject var model:PlayerModel
  @AppStorage("play.episodeSkip") private var mode=EpisodeSkipMode.once.rawValue
  var body:some View{
    PlaybackProgressContent(progress:model.progress) {
    if model.ready,let clip=model.clips.first(where:{$0.contains(model.seconds)}){
      if mode==EpisodeSkipMode.manual.rawValue {
        Button{model.seek(clip.end)}label:{Label("跳过"+clip.title,systemImage:"forward.end").font(.caption.bold()).padding(6)}
          .buttonStyle(.borderedProminent)
      }else if mode==EpisodeSkipMode.show.rawValue{
        Text(clip.title).font(.caption).foregroundStyle(.white).padding(6).background(.black.opacity(0.7),in:Capsule()).allowsHitTesting(false)
      }
    }
    }
  }
}
