import SwiftUI

struct ListenEpisodeReference: Codable, Equatable {
  let id: Int64, course: Bool
  var aid: Int64?, preview: Bool?, barred: Bool?
}
extension SeasonInfo.Episode {
  var listenBV: String { bvid.isEmpty ? (aid.flatMap(ArchiveNumber.bv) ?? "") : bvid }
}
extension ListenTrack {
  init(_ ep: SeasonInfo.Episode, course: Bool, show: String?, origin: ListenOrigin? = nil) {
    let name = [show, ep.label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    self.init(
      .preview(id: ep.listenBV, title: name, cover: ep.cover ?? "", author: nil), cid: ep.cid,
      origin: origin)
    self.episodeSource = .init(
      id: ep.id, course: course, aid: ep.aid, preview: ep.preview, barred: ep.barred)
  }
  var episode: SeasonInfo.Episode? {
    guard let s = episodeSource else { return nil }
    return .init(
      cover: cover, aid: s.aid ?? ArchiveNumber.av(bvid), id: s.id, cid: cid, bvid: bvid,
      title: title,
      long_title: nil, badge: nil, preview: s.preview ?? false, barred: s.barred ?? false)
  }
}
struct EpisodeListenButton: View {
  let episode: SeasonInfo.Episode, course: Bool, seasonTitle: String?
  @ObservedObject var model: PlayerModel
  @Environment(\.listenOrigin) private var origin
  @State private var opened = false
  @State private var transfer: UUID?
  var body: some View {
    HStack {
      Button {
        let t = ListenTrack(episode, course: course, show: seasonTitle, origin: origin)
        let at = model.seconds
        model.engine.pause()
        model.playing = false
        transfer = ListenQueue.shared.handoff(t, at: at)
        opened = true
      } label: {
        Label("听本集", systemImage: "headphones")
      }
      Spacer()
      Button("加入待播") {
        ListenQueue.shared.add(
          ListenTrack(episode, course: course, show: seasonTitle, origin: origin))
        opened = true
      }
    }.disabled(!episode.canRequestPlayback).piliSheet(
      isPresented: $opened,
      onDismiss: {
        if let transfer,
          let t = ListenQueue.shared.returnPosition(
            transfer, bvid: episode.listenBV, cid: episode.cid)
        {
          model.seek(t)
        }
        transfer = nil
      }
    ) {
      PiliNavigationStack { ListenView().toolbar { Button("完成") { opened = false } } }
    }
  }
}
