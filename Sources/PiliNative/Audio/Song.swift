import SwiftUI

struct AudioSong: Decodable {
  var uid: Int64? = nil
  let id: Int64, title: String, author: String?, cover: String?, intro: String?, lyric: String?,
    duration: Int?, bvid: String?
}
extension BiliAPI {
  func song(_ id: Int64) async throws -> AudioSong {
    try await read(
      "/audio/music-service-c/web/song/info", ["sid": "\(id)"], host: "www.bilibili.com",
      as: AudioSong.self)
  }

}
struct SongView: View {
  let id: Int64
  var origin: ListenOrigin? = nil, autoplay = false
  @State private var launched = false
  @State private var song: AudioSong?
  @State private var sharingMoment: MediaMomentSelection?
  @State private var issue: String?
  @State private var retry = 0
  @State private var listen = false
  var body: some View {
    List {
      if let s = song {
        if let cover = s.cover.flatMap(httpsURL) {
          SiteThumbnail(url: cover) {
            $0.resizable().scaledToFit()
          } placeholder: {
            Color.clear
          }.frame(maxHeight: 224)
        }
        Text(s.title).piliFont(.headline)
        Text(s.author ?? "")
        MediaMomentButton(resource: .song(s), selection: $sharingMoment)
        if let intro = s.intro, !intro.isEmpty { Text(intro) }
        Button("播放") {
          ListenQueue.shared.start(ListenTrack(s, origin: origin))
          listen = true
        }
        Button("加入待播") {
          ListenQueue.shared.add(ListenTrack(s, origin: origin))
          listen = true
        }
        if let bv = s.bvid, !bv.isEmpty {
          VideoLink(video: .preview(id: bv, title: s.title, cover: s.cover ?? "", author: s.author))
        }
        if let lyric = s.lyric.flatMap(httpsURL) {
          NavigationLink("歌词") { SongLyric(url: lyric, songID: s.id) }
        }
        NavigationLink("评论") { Discussion(oid: id, type: 14) }
      } else if let issue {
        Text(issue)
        Button("重试") { retry += 1 }
      } else {
        ProgressView()
      }
    }.navigationTitle("音频").task(id: retry) {
      do {
        let result = try await BiliAPI.shared.song(id)
        try Task.checkCancellation()
        song = result
        issue = nil
        if autoplay && !launched {
          launched = true
          ListenQueue.shared.start(ListenTrack(result, origin: origin))
          listen = true
        }
      } catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
    .mediaMomentSheet($sharingMoment)
    .navigationDestination(isPresented: $listen) { ListenView() }
  }
}
