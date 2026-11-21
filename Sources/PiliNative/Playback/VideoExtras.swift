import SwiftUI

/// Notes, summary and chapters, shown as chips in the detail page's tool row.
struct VideoExtraChips: View {
  let video: Video, cid: Int64, jump: (Double) -> Void
  let model: PlayerModel
  @ObservedObject var story: InteractiveStory
  @AppStorage("detail.summary") private var allowSummary = false
  @AppStorage("detail.chapters") private var showChapters = true
  @State private var showSummary = false
  var body: some View {
    if let aid = video.aid {
      NavigationLink {
        ArchiveNotes(aid: aid, interactive: video.rights?.is_stein_gate == 1, model: model, cid: cid, videoTitle: video.title)
      } label: { ArchiveToolChip(title: "笔记", symbol: "note.text") }
    }
    if showChapters, let chapters = story.positions?.chapters, !chapters.isEmpty {
      NavigationLink {
        ArchiveChapterPanel(model: model, bvid: video.bvid, cid: cid, initial: chapters)
      } label: { ArchiveToolChip(title: "分段 \(chapters.count)", symbol: "list.bullet.rectangle") }
    }
    if allowSummary {
      Button { showSummary = true } label: { ArchiveToolChip(title: "视频总结", symbol: "text.quote") }
        .piliSheet(isPresented: $showSummary) {
          PiliNavigationStack {
            VideoSummaryView(video: video, cid: cid, jump: jump).toolbar {
              Button("关闭") { showSummary = false }
            }
          }
        }
    }
  }
}

/// A video's tags, read once per video and account; the page reads them as it opens so the intro
/// has them the moment it is expanded.
@MainActor enum ArchiveTagStore {
  private static var cache: [String: [ArchiveTag]] = [:]
  private static func key(_ bvid: String, _ cid: Int64, _ owner: String) -> String { "\(bvid):\(cid):\(owner)" }
  static func cached(_ bvid: String, _ cid: Int64, _ owner: String) -> [ArchiveTag]? { cache[key(bvid, cid, owner)] }
  @discardableResult static func load(_ bvid: String, _ cid: Int64, owner: String) async -> [ArchiveTag] {
    if let hit = cached(bvid, cid, owner) { return hit }
    guard let result = try? await BiliAPI.shared.read(
      "/x/web-interface/view/detail/tag", ["bvid": bvid, "cid": "\(cid)"], expectedAccount: owner, as: [ArchiveTag].self)
    else { return [] }
    var seen = Set<String>()
    let tags = result.filter { seen.insert($0.id).inserted }
    if cache.count > 60 { cache.removeAll() }
    cache[key(bvid, cid, owner)] = tags
    return tags
  }
}

/// The video's tags, inside the intro: shown only while it is expanded, as the official client's.
struct ArchiveTagRow: View {
  let bvid: String, cid: Int64
  @EnvironmentObject private var accounts: AccountContext
  @State private var tags: [ArchiveTag]
  init(bvid: String, cid: Int64, owner: String) {
    self.bvid = bvid
    self.cid = cid
    _tags = State(initialValue: ArchiveTagStore.cached(bvid, cid, owner) ?? [])
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if !tags.isEmpty {
        // UgcTags: 12 sp in 15 dp-cornered capsules (10 × 5 dp padding), 8 dp apart.
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: OfficialIntro.d(8)) {
            ForEach(tags) { t in
              if let route = t.route {
                LazyLink { LinkDestination(item: route) } label: {
                  Text(t.label).font(OfficialIntro.font(12)).foregroundStyle(OfficialIntro.ga7).lineLimit(1)
                    .padding(.horizontal, OfficialIntro.d(10)).padding(.vertical, OfficialIntro.d(5))
                    .background(OfficialIntro.ga1, in: Capsule())
                }.buttonStyle(.plain)
                  .contextMenu { Button("复制标签") { UIPasteboard.general.string = t.tag_name } }
              }
            }
          }.padding(.horizontal, OfficialIntro.d(12))
        }
        .scrollClipDisabled().padding(.horizontal, -OfficialIntro.d(12))
      }
    }
    .task(id: "\(bvid):\(cid):\(accounts.state.active ?? "")") {
      let owner = accounts.state.active ?? ""
      let loaded = await ArchiveTagStore.load(bvid, cid, owner: owner)
      if !Task.isCancelled, owner == (accounts.state.active ?? "") {
        withAnimation(.easeOut(duration: 0.2)) { tags = loaded }
      }
    }
  }
}

/// An interactive video's choices. (The collection and the team are rows of the intro itself:
/// IntroSeasonRow, IntroStaffs.)
struct VideoExtras: View {
  let choose: (Int64) -> Void
  @ObservedObject var story: InteractiveStory
  var body: some View {
    let d = OfficialIntro.d
    VStack(alignment: .leading, spacing: d(10)) {
      if let node = story.node {
        Label(node.title ?? "互动视频", systemImage: "arrow.triangle.branch")
          .font(OfficialIntro.font(14, .bold)).foregroundStyle(OfficialIntro.text1)
        if let prompt = node.question?.title, !prompt.isEmpty {
          Text(prompt).font(OfficialIntro.font(12)).foregroundStyle(OfficialIntro.ga5)
        }
        ForEach(node.options) { c in
          Button { story.choose(c, navigate: choose) } label: {
            Text(c.option ?? "继续").font(OfficialIntro.font(14)).foregroundStyle(OfficialIntro.text1)
              .frame(maxWidth: .infinity).frame(height: d(36))
              .background(OfficialIntro.ga1, in: RoundedRectangle(cornerRadius: d(4), style: .continuous))
              .contentShape(Rectangle())
          }.buttonStyle(ActionPressStyle())
        }
        if story.canRestart {
          Button("回到故事开头") { story.restart(choose) }
            .font(OfficialIntro.font(12)).foregroundStyle(OfficialIntro.ga5)
        }
      }
      if let issue = story.error {
        Button("加载失败，点击重试") { story.retry() }
          .font(OfficialIntro.font(13)).foregroundStyle(OfficialIntro.ga5).accessibilityHint(issue)
      }
    }
  }
}
