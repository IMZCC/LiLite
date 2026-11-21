import SwiftUI

extension VideoCollection.Part {
  func ordered(_ reversed: Set<Int64>) -> [VideoCollection.Entry] {
    let rows = episodes ?? []
    return reversed.contains(id) ? Array(rows.reversed()) : rows
  }
}
extension VideoCollection.Entry {
  func playable(by owner: String?) -> Video? {
    guard let b = bvid, !b.isEmpty else { return nil }
    return .preview(
      id: b, title: title ?? b, cover: arc?.pic ?? "", author: owner, duration: arc?.duration)
  }
}
/// A collection opened from the intro's "合集 ·" row where there is no panel host (a sheet): the
/// panel's own title bar over the same list.
struct ArchiveCollectionPanel: View {
  let catalog: VideoCollection, current: String, currentCID: Int64, owner: String?, canReverse: Bool
  var subscriptionID: Int64? = nil
  @Binding var reversed: Set<Int64>
  let play: (Video, Int64?) -> Void
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("合集").font(.subheadline)
        Spacer()
        Button {
          TouchFeedback.light()
          dismiss()
        } label: {
          Image(systemName: "xmark").font(.system(size: 15, weight: .medium))
            .foregroundStyle(.secondary).frame(width: 44, height: 44).contentShape(.rect)
        }
        .buttonStyle(.plain).accessibilityLabel("关闭")
      }
      .padding(.leading, 14).padding(.trailing, 2).frame(height: 45)
      Divider().opacity(0.5)
      ArchiveCollectionList(
        catalog: catalog, current: current, currentCID: currentCID, owner: owner, canReverse: canReverse,
        subscriptionID: subscriptionID, reversed: $reversed, play: play, close: { dismiss() })
    }
    .background(Color(uiColor: .systemBackground))
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }
}

/// The official client's collection panel (UgcSeasonPanel), opened under the player like a
/// comment thread: the collection's cover, name and size with its subscribe button; its sections
/// as tabs beside the order switch; its videos as the intro's related cards, the playing one in
/// the accent colour and scrolled into view.
struct ArchiveCollectionList: View {
  let catalog: VideoCollection, current: String, currentCID: Int64, owner: String?, canReverse: Bool
  var subscriptionID: Int64? = nil
  @Binding var reversed: Set<Int64>
  let play: (Video, Int64?) -> Void
  let close: () -> Void
  @AppStorage("play.reverseFirst") private var jump = true
  @Environment(\.panelBottomInset) private var bottomInset
  @State private var picked: Int64?
  private var sections: [VideoCollection.Part] { (catalog.sections ?? []).filter { !($0.episodes ?? []).isEmpty } }
  /// The section with the playing video, until another is picked.
  private var section: VideoCollection.Part? {
    let all = sections
    if let picked, let chosen = all.first(where: { $0.id == picked }) { return chosen }
    return all.first { ($0.episodes ?? []).contains { $0.bvid == current } } ?? all.first
  }
  private var pictures: [GalleryPicture] {
    let urls = [catalog.cover] + sections.flatMap { $0.ordered(reversed).map { $0.arc?.pic } }
    var seen = Set<URL>()
    return urls.compactMap { $0.flatMap(httpsURL) }.filter { seen.insert($0).inserted }.map { .init($0) }
  }
  var body: some View {
    let d = OfficialIntro.d
    // The collection, its subscribe button, sections and order stay put; only the videos scroll.
    VStack(alignment: .leading, spacing: 0) {
      header
      if let section { bar(section) }
      Rectangle().fill(OfficialIntro.ga2).frame(height: 0.5)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            if let section {
              ForEach(section.ordered(reversed)) { entry in
                if let video = entry.playable(by: owner) { row(entry, video).id(entry.id) }
              }
            }
            Color.clear.frame(height: bottomInset + d(12))
          }
          .padding(.top, d(4))
        }
        .onAppear {
          guard let entry = section?.episodes?.first(where: { $0.bvid == current }) else { return }
          DispatchQueue.main.async { proxy.scrollTo(entry.id, anchor: .center) }
        }
        .onChange(of: section?.id) { _, _ in
          if let first = section?.ordered(reversed).first { proxy.scrollTo(first.id, anchor: .top) }
        }
      }
    }
  }
  private var header: some View {
    let d = OfficialIntro.d
    let count = sections.reduce(0) { $0 + ($1.episodes?.count ?? 0) }
    let photos = pictures
    return HStack(spacing: d(10)) {
      if let cover = photos.first {
        GalleryLink(photos, index: 0) {
          Rectangle().fill(OfficialIntro.ga1)
            .overlay { SiteThumbnail(url: cover.url) { $0.resizable().scaledToFill() } placeholder: { Color.clear } }
            .frame(width: d(64), height: d(40))
            .clipShape(RoundedRectangle(cornerRadius: d(4), style: .continuous))
        }
        .accessibilityLabel("合集封面")
      }
      VStack(alignment: .leading, spacing: d(3)) {
        Text(catalog.title ?? "视频合集").font(OfficialIntro.font(15, .medium)).foregroundStyle(OfficialIntro.text1)
          .lineLimit(1)
        Text("共 \(count) 个视频").font(OfficialIntro.font(12)).foregroundStyle(OfficialIntro.ga5).monospacedDigit()
      }
      Spacer(minLength: d(8))
      ArchiveSeasonSubscriptionButton(item: subscriptionID, catalog: catalog.id, currentBV: current, compact: true)
    }
    .padding(.horizontal, d(12)).padding(.top, d(12)).padding(.bottom, d(8))
  }
  /// The sections as tabs (or the one section's name), and the order switch.
  private func bar(_ shown: VideoCollection.Part) -> some View {
    let d = OfficialIntro.d
    let all = sections
    return HStack(spacing: d(8)) {
      if all.count > 1 {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: d(16)) {
            ForEach(all) { part in
              let on = part.id == shown.id
              Button {
                TouchFeedback.light()
                withAnimation(.snappy(duration: 0.2)) { picked = part.id }
              } label: {
                Text(part.title ?? "合集").font(OfficialIntro.font(13, on ? .medium : .regular))
                  .foregroundStyle(on ? OfficialIntro.text1 : OfficialIntro.ga5)
                  .lineLimit(1).frame(minHeight: d(30)).contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityAddTraits(on ? .isSelected : [])
            }
          }
        }
      } else {
        Text(shown.title ?? "合集").font(OfficialIntro.font(13)).foregroundStyle(OfficialIntro.ga7).lineLimit(1)
          .frame(minHeight: d(30))
        Spacer(minLength: 0)
      }
      if canReverse, (shown.episodes?.count ?? 0) > 1 {
        let backwards = reversed.contains(shown.id)
        Button {
          TouchFeedback.light()
          if backwards { reversed.remove(shown.id) } else { reversed.insert(shown.id) }
          if jump, let first = shown.ordered(reversed).first, let video = first.playable(by: owner),
            video.bvid != current {
            play(video, first.cid)
            close()
          }
        } label: {
          HStack(spacing: d(3)) {
            Image(systemName: "arrow.up.arrow.down").font(.system(size: d(11), weight: .medium))
            Text(backwards ? "倒序" : "正序").font(OfficialIntro.font(12))
          }
          .foregroundStyle(OfficialIntro.ga5).frame(minHeight: d(30)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(backwards ? "倒序播放，轻点改为正序" : "正序播放，轻点改为倒序")
      }
    }
    .padding(.horizontal, d(12)).padding(.bottom, d(4))
  }
  private func row(_ entry: VideoCollection.Entry, _ video: Video) -> some View {
    let d = OfficialIntro.d
    let playing = video.bvid == current
    let parts = entry.pages ?? []
    return VStack(alignment: .leading, spacing: 0) {
      Button {
        TouchFeedback.light()
        if !playing || (entry.cid != nil && entry.cid != currentCID) { play(video, entry.cid ?? entry.page?.cid) }
        close()
      } label: {
        HStack(alignment: .top, spacing: d(8)) {
          Rectangle().fill(OfficialIntro.ga1)
            .overlay { SiteThumbnail(url: video.cover) { $0.resizable().scaledToFill() } placeholder: { Color.clear } }
            .frame(width: d(112), height: d(63))
            .overlay(alignment: .bottomTrailing) {
              if let length = video.duration, length > 0 {
                Text(clockText(Double(length))).font(OfficialIntro.font(10)).monospacedDigit().foregroundStyle(.white)
                  .padding(.horizontal, d(3)).frame(height: d(16))
                  .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: d(2), style: .continuous))
                  .padding(d(4))
              }
            }
            .overlay(alignment: .topLeading) {
              if let badge = entry.badge, !badge.isEmpty {
                Text(badge).font(OfficialIntro.font(10, .medium)).foregroundStyle(.white)
                  .padding(.horizontal, d(4)).frame(height: d(16))
                  .background(Color.accentColor, in: RoundedRectangle(cornerRadius: d(2), style: .continuous))
                  .padding(d(4))
              }
            }
            .clipShape(RoundedRectangle(cornerRadius: d(4), style: .continuous))
          VStack(alignment: .leading, spacing: 0) {
            Text(video.title).font(OfficialIntro.font(14, playing ? .medium : .regular))
              .foregroundStyle(playing ? Color.accentColor : OfficialIntro.text1)
              .lineLimit(2).multilineTextAlignment(.leading)
            Spacer(minLength: d(2))
            HStack(spacing: d(4)) {
              if playing {
                Image(systemName: "waveform").font(.system(size: d(11), weight: .semibold))
                  .symbolEffect(.variableColor.iterative, options: .repeating)
                Text("正在播放")
              } else if parts.count > 1 {
                Text("共 \(parts.count)P")
              }
            }
            .font(OfficialIntro.font(12))
            .foregroundStyle(playing ? Color.accentColor : OfficialIntro.ga5)
            .frame(height: d(17))
          }
          .frame(maxWidth: .infinity, minHeight: d(63), maxHeight: d(63), alignment: .topLeading)
        }
        .padding(.horizontal, d(12)).padding(.vertical, d(8))
        .background(playing ? OfficialIntro.ga1.opacity(0.6) : Color.clear)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .archiveCover(video)
      .accessibilityLabel(video.title + (playing ? "，正在播放" : ""))
      // Parts sit under their video as a strip, like the original's PagePanel.
      if parts.count > 1 {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: d(8)) {
            ForEach(parts) { part in
              let on = playing && currentCID == part.cid
              Button {
                TouchFeedback.light()
                if !on { play(video, part.cid) }
                close()
              } label: {
                Text("P\(part.page) " + part.part).font(OfficialIntro.font(12)).lineLimit(1)
                  .foregroundStyle(on ? Color.accentColor : OfficialIntro.text1)
                  .padding(.horizontal, d(10)).frame(height: d(30)).frame(maxWidth: d(160))
                  .background(on ? Color.accentColor.opacity(0.12) : OfficialIntro.ga1,
                    in: RoundedRectangle(cornerRadius: d(4), style: .continuous))
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.horizontal, d(12))
        }
        .padding(.bottom, d(8))
      }
    }
  }
}

/// The list inside a panel: a pick closes the panel it sits in.
struct CollectionPanelContent: View {
  let list: ArchiveCollectionList
  @Environment(\.replyPanelDismiss) private var dismissPanel
  var body: some View {
    ArchiveCollectionList(
      catalog: list.catalog, current: list.current, currentCID: list.currentCID, owner: list.owner,
      canReverse: list.canReverse, subscriptionID: list.subscriptionID, reversed: list.$reversed,
      play: list.play, close: { dismissPanel?() })
  }
}

/// The intro's "合集 ·" row and what it opens: the panel under the player, read from where the
/// row sits (the video page's panel host), or a sheet where there is none.
struct IntroCollectionEntry: View {
  let list: ArchiveCollectionList
  let position: String?
  @Environment(\.replyPanelPresenter) private var presenter
  @State private var sheet = false
  var body: some View {
    IntroSeasonRow(title: list.catalog.title ?? "视频合集", position: position) {
      if presenter?.push("合集", AnyView(CollectionPanelContent(list: list))) != true { sheet = true }
    }
    .piliSheet(isPresented: $sheet) {
      ArchiveCollectionPanel(
        catalog: list.catalog, current: list.current, currentCID: list.currentCID, owner: list.owner,
        canReverse: list.canReverse, subscriptionID: list.subscriptionID, reversed: list.$reversed,
        play: list.play)
    }
  }
}
