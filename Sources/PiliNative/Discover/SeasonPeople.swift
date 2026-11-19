import SwiftUI

struct SeasonPeople: View {
  let actors: String, staff: String
  var body: some View {
    List {
      credits("角色与配音", actors)
      credits("制作人员", staff)
    }.contextPushHost().navigationTitle("演职人员")
  }
  @ViewBuilder private func credits(_ title: String, _ raw: String) -> some View {
    if !raw.isEmpty {
      Section(title) {
        ForEach(Array(raw.split(whereSeparator: \.isNewline).enumerated()), id: \.offset) {
          _, line in
          let text = String(line).trimmingCharacters(in: .whitespaces)
          let cut = text.firstIndex(where: { $0 == "：" || $0 == ":" })
          if let cut {
            let role = String(text[..<cut])
            let name = String(text[text.index(after: cut)...]).trimmingCharacters(in: .whitespaces)
            VStack(alignment: .leading) {
              Text(role).font(.caption).foregroundStyle(.secondary)
              Text(name).textSelection(.enabled)
            }
            .contextMenu {
              Button("复制") { UIPasteboard.general.string = text }
              if !name.isEmpty { ContextLink("搜索名字", systemImage: "magnifyingglass") { SearchView(keyword: name) } }
            }
          } else {
            Text(text).textSelection(.enabled)
          }
        }
      }
    }
  }
}
struct SeasonCatalogEntry: View {
  let episode: SeasonInfo.Episode, group: SeasonInfo.CatalogGroup, info: SeasonInfo, id: Int64
  @EnvironmentObject private var accounts: AccountContext
  @State private var resolved: SeasonInfo.Episode?
  @State private var error: String?
  @State private var retry = 0
  var body: some View {
    Group {
      if let e = episode.canRequestPlayback ? episode : resolved {
        EpisodePlayer(
          episode: e,
          initialSeconds: info.activeProgress?.last_ep_id == e.id
            ? info.activeProgress?.last_time.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } : nil,
          sequence: group.episodes.map { $0.id == e.id ? e : $0 }, seasonType: info.type,
          seasonTitle: info.title, seasonID: id)
      } else if let error {
        VStack {
          Text(error)
          Button("重试") { retry += 1 }
        }
      } else {
        ProgressView()
      }
    }.task(id: "\(episode.id):\(accounts.state.owner(.role(.heartbeat)) ?? ""):\(retry)") {
      guard !episode.canRequestPlayback else { return }
      resolved = nil
      error = nil
      do {
        let entry = try await BiliAPI.shared.catalogEpisode(
          episode, history: accounts.state.owner(.role(.heartbeat)) ?? "")
        try Task.checkCancellation()
        resolved = entry
      } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
  }
}
