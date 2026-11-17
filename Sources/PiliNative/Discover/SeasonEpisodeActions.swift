import SwiftUI

struct SeasonEpisodeActions: View {
  let entry: SeasonInfo.Episode, course: Bool, series: String?
  @EnvironmentObject private var accounts: AccountContext
  @State private var known: Bool?
  @State private var busy = false
  @State private var note: String?
  private var link: URL? {
    guard entry.id > 0 else { return nil }
    return URL(
      string: "https://www.bilibili.com/" + (course ? "cheese/play/ep" : "bangumi/play/ep")
        + String(entry.id))
  }
  private var aid: Int64? { entry.aid ?? ArchiveNumber.av(entry.bvid) }
  var body: some View {
    HStack {
      if !course, let uid = accounts.state.active, let aid, aid > 0 {
        Menu {
          if known != true { Button("加入稍后再看") { Task { await update(true, aid: aid, uid: uid) } } }
          if known != false {
            Button("从稍后再看移除") { Task { await update(false, aid: aid, uid: uid) } }
          }
        } label: {
          Label(
            known == true ? "已加入稍后再看" : "稍后再看", systemImage: known == true ? "clock.fill" : "clock")
        }.disabled(busy)
      }
      if let link {
        Menu {
          ShareLink(item: link, subject: Text(series ?? entry.label))
          Button("复制链接") { UIPasteboard.general.url = link }
          NavigationLink("生成海报") {
            SharePoster(
              content: .init(
                title: series ?? entry.label, body: entry.share_copy ?? entry.label, author: "",
                date: "", kind: course ? "课程" : "剧集", link: link,
                cover: entry.cover.flatMap(httpsURL)))
          }
        } label: {
          Label("分享", systemImage: "square.and.arrow.up")
        }
      }
    }.alert("稍后再看", isPresented: .init(get: { note != nil }, set: { if !$0 { note = nil } })) {
      Button("好") {}
    } message: {
      Text(note ?? "")
    }
  }
  @MainActor private func update(_ add: Bool, aid: Int64, uid: String) async {
    guard accounts.state.active == uid, self.aid == aid, !course, !busy else { return }
    busy = true
    defer { busy = false }
    do {
      let fields: [String: String] =
        add
        ? (entry.bvid.isEmpty ? ["aid": String(aid)] : ["bvid": entry.bvid])
        : ["resources": String(aid)]
      try await BiliAPI.shared.submit(
        add ? "/x/v2/history/toview/add" : "/x/v2/history/toview/v2/dels", fields,
        expectedAccount: uid)
      guard accounts.state.active == uid, self.aid == aid else { return }
      known = add
      note = add ? "已加入稍后再看" : "已从稍后再看移除"
    } catch { if accounts.state.active == uid { note = error.localizedDescription } }
  }
}
