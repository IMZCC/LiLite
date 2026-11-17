import SwiftUI

/// Resolve the actual first CID before launching the selected author/collection source.
struct ArchiveListenEntry: View {
  let video: Video, origin: ListenOrigin
  @State private var open = false
  @State private var retry = 0
  @State private var issue: String?
  var body: some View {
    Group {
      if open {
        ListenView()
      } else if let issue {
        VStack {
          Text(issue)
          Button("重试") { retry += 1 }
        }
      } else {
        ProgressView()
      }
    }
    .task(id: retry) {
      guard !open else { return }
      issue = nil
      do {
        let detail = try await BiliAPI.shared.detail(video.bvid)
        guard let cid = detail.cid ?? detail.pages?.first?.cid, cid > 0 else {
          throw ServiceError("未找到可播放的分 P")
        }
        try Task.checkCancellation()
        ListenQueue.shared.start(.init(detail, cid: cid, origin: origin))
        open = true
      } catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
  }
}

/// Start the identified resource directly; fetching its optional web metadata does not gate playback.
struct AudioCardEntry: View {
  let id: Int64, title: String, origin: ListenOrigin
  @State private var launched = false
  var body: some View {
    ListenView().onAppear {
      guard !launched, id > 0 else { return }
      launched = true
      ListenQueue.shared.start(
        ListenTrack(
          AudioSong(
            id: id, title: title.isEmpty ? "AU\(id)" : title, author: nil, cover: nil, intro: nil,
            lyric: nil, duration: nil, bvid: nil), origin: origin))
    }
  }
}
