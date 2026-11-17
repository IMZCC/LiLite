import SwiftUI

struct SongLyric: View {
  let url: URL, songID: Int64?
  @ObservedObject private var queue = ListenQueue.shared
  @State private var lyrics: LyricLines?
  @State private var issue: String?
  @State private var retry = 0
  private var current: Bool { songID != nil && queue.current?.songID == songID }
  var body: some View {
    List {
      if let issue {
        Text(issue)
        Button("重试") { retry += 1 }
      } else if let lyrics {
        if lyrics.lines.isEmpty { Text("暂无歌词") }
        let active = current ? lyrics.active(at: queue.clock) : nil
        ForEach(lyrics.lines) { l in
          if let t = l.seconds, current {
            Button {
              queue.seek(t)
            } label: {
              HStack {
                Text(l.text)
                Spacer()
                Text(clockText(t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
              }
            }.fontWeight(active == l.id ? .bold : .regular).foregroundStyle(
              active == l.id ? Color.accentColor : Color.primary)
          } else {
            Text(l.text).textSelection(.enabled)
          }
        }
      } else {
        ProgressView()
      }
    }.navigationTitle("歌词").task(id: retry) {
      issue = nil
      let config = URLSessionConfiguration.ephemeral
      config.httpCookieStorage = nil
      config.urlCredentialStorage = nil
      config.httpShouldSetCookies = false
      let session = URLSession(configuration: config, delegate: CertificateSessionDelegate(), delegateQueue: nil)
      defer { session.invalidateAndCancel() }
      do {
        guard url.scheme?.lowercased() == "https" else { throw ServiceError("歌词地址无效") }
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.httpShouldHandleCookies = false
        let (bytes, h) = try await session.bytes(for: r)
        let limit = 1024 * 1024
        guard let http = h as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https",
          h.expectedContentLength <= limit
        else { throw ServiceError("歌词加载失败") }
        var d = Data()
        for try await b in bytes {
          guard d.count < limit else { throw ServiceError("歌词文件过大") }
          d.append(b)
        }
        try Task.checkCancellation()
        lyrics = LyricLines(String(decoding: d, as: UTF8.self))
      } catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
  }
}
