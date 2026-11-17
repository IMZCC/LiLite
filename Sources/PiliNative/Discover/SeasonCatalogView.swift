import SwiftUI

struct SeasonCatalogView: View {
  let info: SeasonInfo, fallback: Season
  private let catalog: [SeasonInfo.CatalogGroup]
  private let resumeEntry: (SeasonInfo.Episode, SeasonInfo.CatalogGroup)?
  init(info: SeasonInfo, fallback: Season) {
    self.info = info
    self.fallback = fallback
    let groups = info.groups
    catalog = groups
    resumeEntry = info.resume(in: groups)
  }
  @State private var tags: [Tag] = []
  struct Tag: Decodable, Identifiable {
    let tag_id: Int64, tag_name: String
    var id: Int64 { tag_id }
  }
  private var sid: Int64 { info.season_id ?? fallback.id }
  private func player(_ e: SeasonInfo.Episode, _ g: SeasonInfo.CatalogGroup) -> some View {
    SeasonCatalogEntry(episode: e, group: g, info: info, id: sid)
  }
  var body: some View {
    Section {
      if let url = httpsURL(info.cover ?? fallback.cover) {
        GalleryLink([.init(url)], index: 0) {
          HStack {
            RemoteArtwork(url: url) { p in
              if let i = p.image {
                i.resizable().scaledToFill()
              } else {
                Color.secondary.opacity(0.12)
              }
            }.frame(width: 70, height: 90).clipped()
            VStack(alignment: .leading) {
              Text(info.title).piliFont(.headline)
              if let rating = info.rating?.score {
                Text("\(rating.formatted()) 分").foregroundStyle(.secondary)
              }
              if let s = info.subtitle, !s.isEmpty { Text(s).piliFont(.caption) }
            }
          }
        }
      }
      if let (e, g) = resumeEntry {
        NavigationLink {
          player(e, g)
        } label: {
          Label(
            (info.activeProgress?.last_ep_id == e.id ? "继续观看：" : "开始观看：") + e.label,
            systemImage: "play.fill")
        }
      }
    }
    if let reason = info.viewingRestriction { Label(reason, systemImage: "lock") }
    SeasonFollow(id: sid)
    if let all = info.seasons, all.count > 1 {
      Section("系列") {
        ForEach(Array(all.enumerated()), id: \.offset) { _, r in
          if let n = r.season_id, n > 0 {
            let title = r.season_title ?? "第 \(n) 季"
            if n == sid {
              Label(title, systemImage: "checkmark").foregroundStyle(.secondary)
            } else {
              NavigationLink(title) {
                SeasonView(
                  season: .init(season_id: n, title: title, cover: r.cover ?? "", index_show: nil))
              }
            }
          }
        }
      }
    }
    if let media = info.media_id, media > 0 {
      NavigationLink("点评") {
        SeasonReviews(media: media, publishing: info.rights?.allow_review != 0)
      }
    }
    Section("作品信息") {
      let details =
        (info.areas ?? []).compactMap(\.name)
        + [info.publish?.pub_time_show, info.new_ep?.desc].compactMap { $0 }
      if !details.isEmpty { Text(details.joined(separator: " · ")).piliFont(.subheadline) }
      if let n = info.stat?.views { LabeledContent("播放", value: n.formatted()) }
      if let n = info.stat?.danmakus { LabeledContent("弹幕", value: n.formatted()) }
      if let s = info.evaluate, !s.isEmpty { Text(s).textSelection(.enabled) }
      if let n = info.rating?.count, n > 0 { LabeledContent("参与评分", value: n.formatted()) }
      if let original = info.jp_title, !original.isEmpty, original != info.title {
        LabeledContent("原名", value: original).textSelection(.enabled)
      }
      if let alias = info.alias, !alias.isEmpty {
        LabeledContent("别名", value: alias).textSelection(.enabled)
      }
      if !(info.actors ?? "").isEmpty || !(info.staff ?? "").isEmpty {
        NavigationLink("角色与演职人员") {
          SeasonPeople(actors: info.actors ?? "", staff: info.staff ?? "")
        }
      }
      if let up = info.up_info, let uid = up.mid, uid > 0 {
        NavigationLink(up.uname ?? "出品方") { CreatorSpace(mid: uid, name: up.uname ?? "出品方") }
      }
      let tagNames = Set(tags.map(\.tag_name))
      let categories = (info.styles ?? []).filter {
        !$0.isEmpty && !tagNames.contains($0)
      }
      ForEach(Array(categories.enumerated()), id: \.offset) { _, style in
        NavigationLink(style) { SearchView(keyword: style) }
      }

      ForEach(tags) { t in
        NavigationLink(t.tag_name) { SearchView(keyword: t.tag_name) }.contextMenu {
          Button("复制标签") { UIPasteboard.general.string = t.tag_name }
        }
      }
    }.task(id: sid) {
      tags = []
      guard let (e, _) = resumeEntry, !e.bvid.isEmpty else { return }
      let result = try? await BiliAPI.shared.read(
        "/x/web-interface/view/detail/tag", ["bvid": e.bvid, "cid": String(e.cid)], as: [Tag].self)
      if !Task.isCancelled { tags = result ?? [] }
    }
    ForEach(catalog) { g in
      Section(g.title) {
        if g.episodes.lazy.filter(\.allowCacheEntry).prefix(2).count > 1 {
          NavigationLink("选择多集缓存") {
            SeasonBatchCache(episodes: g.episodes, course: false, title: g.title)
          }
        }
        ForEach(g.episodes) { e in
          if e.catalogPlayable {
            NavigationLink {
              player(e, g)
            } label: {
              EpisodeCatalogRow(episode: e, course: false)
            }
          } else {
            EpisodeCatalogRow(episode: e, course: false)
          }
        }
      }
    }
    if catalog.isEmpty { Text("暂无剧集").foregroundStyle(.secondary) }
  }
}
struct EpisodeCatalogRow: View {
  let episode: SeasonInfo.Episode, course: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(episode.label)
      let subtitle = [
        episode.isLiveCourse
          ? "直播课"
          : (episode.accessReason
            ?? ((episode.barred || (episode.cid <= 0 && !episode.canResolveCID)) ? "暂不可播放" : nil)),
        episode.preview ? "试看" : nil,
        episode.badge,
        episode.duration.flatMap { $0 > 0 ? clockText(Double($0) / (course ? 1 : 1000)) : nil },
        course ? episode.play.map { "\($0) 次播放" } : nil,
      ].compactMap { $0 }.filter { !$0.isEmpty }
      if !subtitle.isEmpty {
        Text(subtitle.joined(separator: " · ")).piliFont(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
