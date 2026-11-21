import SwiftUI

struct SongLyric: View {
  let url: URL, songID: Int64?
  @ObservedObject private var queue = ListenQueue.shared
  @State private var lyrics: LyricLines?
  @State private var activeLine: Int?
  @State private var issue: String?
  @State private var retry = 0
  private var current: Bool { songID != nil && queue.current?.songID == songID }
  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        if let issue {
          ContentUnavailableView {
            Label("歌词未能载入", systemImage: "quote.bubble")
          } description: { Text(issue) } actions: { Button("重试") { retry += 1 } }
            .padding(.top, 60)
        } else if let lyrics {
          let active = current ? activeLine : nil
          LazyVStack(spacing: 18) {
            if lyrics.lines.isEmpty {
              Text("暂无歌词").foregroundStyle(.secondary).padding(.top, 60)
            }
            ForEach(lyrics.lines) { l in
              let on = active == l.id
              Group {
                if let t = l.seconds, current {
                  Button { queue.seek(t) } label: { Text(l.text) }.buttonStyle(.plain)
                } else {
                  Text(l.text).textSelection(.enabled)
                }
              }
              .font(on ? .title3.weight(.bold) : .body)
              .foregroundStyle(on ? Color.primary : Color.secondary)
              .multilineTextAlignment(.center)
              .scaleEffect(on ? 1.04 : 1)
              .animation(.snappy(duration: 0.25), value: on)
              .id(l.id)
            }
          }
          .padding(.horizontal, 24).padding(.vertical, 120)
          .frame(maxWidth: .infinity)
          .onReceive(queue.progress.$seconds) { seconds in
            let line = current ? lyrics.active(at: seconds) : nil
            if activeLine != line { activeLine = line }
          }
          .onChange(of: active) { _, id in
            guard let id else { return }
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
          }
        } else {
          ProgressView().padding(.top, 60)
        }
      }
    }
    .navigationTitle("歌词").navigationBarTitleDisplayMode(.inline).task(id: retry) {
      issue = nil
      do {
        let result = try await Self.load(url)
        try Task.checkCancellation()
        lyrics = result
      } catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
  }
  nonisolated private static func load(_ url: URL) async throws -> LyricLines {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    config.httpShouldSetCookies = false
    let session = URLSession(configuration: config, delegate: CertificateSessionDelegate(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
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
    return LyricLines(String(decoding: d, as: UTF8.self))
  }
}
