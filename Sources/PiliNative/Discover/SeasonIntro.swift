import SwiftUI

/// The bangumi page's 简介 as the official app lays it out: the category, title and 追番 on one
/// line; plays, follows and the score with 详情; the episode's own action row; the 选集 strip;
/// the extra sections (花絮, PV) as tabs over a row of thumbnails; the related creators; then
/// related shows. 选集 and the extra sections open in full in a panel over the intro.
struct SeasonIntro: View {
  let season: SeasonInfo?
  let episode: SeasonInfo.Episode
  let sequence: [SeasonInfo.Episode]
  let seasonID: Int64?
  let seasonType: Int?
  @ObservedObject var model: PlayerModel
  @Binding var sharingMoment: MediaMomentSelection?
  let choose: @MainActor (SeasonInfo.Episode) async throws -> Void
  let retry: () -> Void
  @Environment(\.replyPanelPresenter) private var presenter
  @State private var detail = false
  @State private var allEpisodes = false
  @State private var allExtras = false
  @State private var extraTab = 0
  @State private var tags: [SeasonCatalogView.Tag] = []
  @State private var facts: SeasonEpisodeFacts?
  @State private var related: [SeasonRelatedPage.Item] = []
  private var title: String { season?.title ?? episode.label }
  private var type: Int? { season?.type ?? seasonType }
  private var showID: Int64? { (season?.season_id ?? seasonID).flatMap { $0 > 0 ? $0 : nil } }
  var body: some View {
    // A plain stack: a handful of sections, so the page height is never an estimate.
    VStack(alignment: .leading, spacing: 0) {
      titleRow
      statsRow.padding(.top, 8)
      if let reason = season?.viewingRestriction {
        Label(reason, systemImage: "lock").font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
      }
      EngagementBar(
        item: .init(bvid: episode.bvid, aid: episode.aid, episode: episode.id, copyright: 1),
        counts: counts,
        extras: AnyView(
          SeasonActionColumns(
            episode: episode, seasonTitle: season?.title, seasonType: seasonType, model: model,
            shares: facts?.stat?.share, sharingMoment: $sharingMoment)))
        .padding(.top, 14)
      if let error = model.error ?? model.qualityError {
        HStack {
          Text(error).font(.footnote).foregroundStyle(.secondary)
          Button("重试", action: retry).piliGlassButton().controlSize(.small)
        }.padding(.top, 8)
      }
      if let all = season?.seasons, all.count > 1 { seasonsRow(all).padding(.top, 16) }
      if sequence.count > 1 { episodeSection.padding(.top, 20) }
      if !extraGroups.isEmpty { extrasSection.padding(.top, 22) }
      if !producers.isEmpty { producerSection.padding(.top, 22) }
      if !related.isEmpty { relatedSection.padding(.top, 18) }
    }
    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 24)
    .piliSheet(isPresented: $detail) {
      if let season { SeasonDetailSheet(info: season, tags: tags, current: episode) }
    }
    .piliSheet(isPresented: $allEpisodes) {
      PiliNavigationStack {
        episodeGrid.navigationTitle("选集").navigationBarTitleDisplayMode(.inline)
      }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    .piliSheet(isPresented: $allExtras) {
      PiliNavigationStack {
        extrasPanel(extraTab).navigationTitle("更多内容").navigationBarTitleDisplayMode(.inline)
      }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    .task(id: "\(episode.bvid):\(episode.cid)") {
      guard !episode.bvid.isEmpty, episode.cid > 0 else { return }
      let result = try? await BiliAPI.shared.read(
        "/x/web-interface/view/detail/tag", ["bvid": episode.bvid, "cid": String(episode.cid)],
        as: [SeasonCatalogView.Tag].self)
      if !Task.isCancelled { tags = result ?? [] }
    }
    .task(id: episode.id) {
      facts = nil
      guard episode.id > 0 else { return }
      let result = try? await BiliAPI.shared.read(
        "/pgc/season/episode/web/info", ["ep_id": String(episode.id)], as: SeasonEpisodeFacts.self)
      if !Task.isCancelled { facts = result }
    }
    .task(id: showID ?? 0) {
      guard let showID else { return }
      let result = try? await BiliAPI.shared.read(
        "/pgc/season/web/related/recommend", ["season_id": String(showID)], as: SeasonRelatedPage.self)
      if !Task.isCancelled { related = (result?.season ?? []).filter { $0.id > 0 && $0.id != showID } }
    }
  }
  /// The episode's own likes, coins and favourites, as the official action row shows them.
  private var counts: EngagementCounts? {
    guard let s = facts?.stat else { return nil }
    return .init(
      like: s.like.map { Int(clamping: $0) }, coin: s.coin.map { Int(clamping: $0) },
      favorite: s.favorite.map { Int(clamping: $0) })
  }
  /// Sections after the main run (PV, 花絮, 特别篇), as the original's SectionPanel.
  private var extraGroups: [SeasonInfo.CatalogGroup] {
    // Every group but the one the strip above already shows.
    let shown = Set(sequence.map(\.id))
    return (season?.groups ?? []).filter { g in !g.episodes.isEmpty && Set(g.episodes.map(\.id)) != shown }
  }
  private var producers: [SeasonEpisodeFacts.Up] {
    let list = (facts?.related_up ?? []).filter { $0.id > 0 }
    if !list.isEmpty { return list }
    if let up = season?.up_info, let mid = up.mid, mid > 0 {
      return [.init(mid: mid, uname: up.uname, avatar: up.avatar, is_follow: nil)]
    }
    return []
  }
  // MARK: Title and facts

  private var titleRow: some View {
    HStack(alignment: .center, spacing: 8) {
      if let kind = Self.kind(type) {
        HStack(spacing: 3) {
          Image(systemName: "square.grid.2x2.fill").font(.system(size: 10, weight: .bold))
          Text(kind).font(.footnote.weight(.medium))
        }
        .foregroundStyle(.tint).padding(.horizontal, 9).frame(height: 26)
        .background(Color.accentColor.opacity(0.1), in: Capsule())
      }
      Text(title).font(.title3.weight(.semibold)).lineLimit(2).layoutPriority(1)
        .textSelection(.enabled)
      if let badge = season?.badge, !badge.isEmpty { SeasonBadgeTag(text: badge) }
      Spacer(minLength: 6)
      if let showID { SeasonFollowButton(id: showID, type: type) }
    }
  }
  private var statsRow: some View {
    HStack(spacing: 12) {
      if let n = season?.stat?.views, n > 0 { Self.counter("play.rectangle", n) }
      if let n = season?.stat?.favorites, n > 0 { Self.counter("heart", n) }
      if let score = season?.rating?.score, score > 0 {
        Text(score.formatted(.number.precision(.fractionLength(1))) + "分").foregroundStyle(.orange)
      }
      Spacer(minLength: 8)
      if season != nil {
        Button {
          TouchFeedback.light()
          detail = true
        } label: {
          HStack(spacing: 2) {
            Text("详情")
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
          }.frame(minHeight: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel("作品详情")
      }
    }
    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
  }
  static func counter(_ symbol: String, _ value: Int64) -> some View {
    HStack(spacing: 3) {
      Image(systemName: symbol).imageScale(.small)
      Text(value.formatted(.number.notation(.compactName)))
    }.monospacedDigit()
  }
  /// The official app's category tag before the title.
  static func kind(_ type: Int?) -> String? {
    switch type {
    case 1: "番剧"
    case 2: "电影"
    case 3: "纪录片"
    case 4: "国创"
    case 5: "电视剧"
    case 7: "综艺"
    default: nil
    }
  }
  // MARK: Seasons

  private func seasonsRow(_ all: [SeasonInfo.Related]) -> some View {
    let current = showID
    // The official season row: text tabs 24 apart, the current one bold over a short bar.
    return ScrollView(.horizontal, showsIndicators: false) {
      HStack(alignment: .top, spacing: 24) {
        ForEach(Array(all.enumerated()), id: \.offset) { _, r in
          if let n = r.season_id, n > 0 {
            let name = r.season_title ?? "第 \(n) 季"
            if n == current {
              VStack(spacing: 4) {
                Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Capsule().fill(Color.accentColor).frame(width: 18, height: 4)
              }
              .accessibilityAddTraits(.isSelected)
            } else {
              NavigationLink {
                SeasonView(season: .init(season_id: n, title: name, cover: r.cover ?? "", index_show: nil))
              } label: {
                Text(name).font(.subheadline).foregroundStyle(.secondary)
                  .padding(.bottom, 8).contentShape(Rectangle())
              }.buttonStyle(.plain)
            }
          }
        }
      }.padding(.horizontal, 16).padding(.vertical, 2)
    }
    .scrollClipDisabled().padding(.horizontal, -16)
  }
  // MARK: Episodes

  private var episodeSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      SeasonSectionHeader(
        title: "选集",
        trailing: (season?.new_ep?.desc).flatMap { $0.isEmpty ? nil : $0 }
          ?? "全\(sequence.count)\(SeasonEpisodeText.unit(type))"
      ) {
        if presenter?.push("选集", AnyView(episodeGrid)) != true { allEpisodes = true }
      }
      SeasonEpisodeStrip(episodes: sequence, current: episode.id, type: type, pick: choose)
    }
  }
  private var episodeGrid: some View {
    SeasonEpisodeGrid(
      episodes: sequence, current: episode.id, type: type, summary: season?.new_ep?.desc, pick: choose)
  }
  // MARK: Extra sections

  private var extrasSection: some View {
    let groups = extraGroups
    let index = min(max(0, extraTab), groups.count - 1)
    let group = groups[index]
    return VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 4) {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { i, g in
              if i > 0 {
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 1, height: 14)
                  .padding(.horizontal, 12)
              }
              Button {
                withAnimation(.snappy(duration: 0.2)) { extraTab = i }
              } label: {
                Text(g.title).font(.body.weight(i == index ? .medium : .regular))
                  .foregroundStyle(i == index ? Color.primary : Color.secondary)
                  .frame(minHeight: 32).contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityAddTraits(i == index ? .isSelected : [])
            }
          }
        }
        Button {
          if presenter?.push("更多内容", AnyView(extrasPanel(index))) != true { allExtras = true }
        } label: {
          Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel("全部" + group.title)
      }
      SeasonExtraStrip(episodes: group.episodes, current: episode.id, pick: choose).id(group.id)
    }
  }
  private func extrasPanel(_ start: Int) -> some View {
    SeasonExtrasPanel(groups: extraGroups, start: start, current: episode.id, pick: choose)
  }
  // MARK: Creators and related shows

  private var producerSection: some View {
    let list = producers
    return VStack(alignment: .leading, spacing: 10) {
      SeasonSectionHeader(title: "相关UP主", trailing: "共\(list.count)位")
      ForEach(list) { up in
        HStack(spacing: 10) {
          NavigationLink {
            CreatorSpace(mid: up.id, name: up.uname ?? "UP 主")
          } label: {
            HStack(spacing: 10) {
              SiteThumbnail(url: up.avatar.flatMap(httpsURL)) { $0.resizable().scaledToFill() } placeholder: {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.tertiary)
              }
              .frame(width: 40, height: 40).clipShape(Circle())
              Text(up.uname ?? "UP 主").font(.subheadline).foregroundStyle(.primary).lineLimit(1)
              Spacer(minLength: 0)
            }.contentShape(Rectangle())
          }.buttonStyle(.plain)
          CreatorQuickRelation(mid: up.id, knownFollowing: up.is_follow == 1)
        }
      }
    }
  }
  private var relatedSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      SeasonSectionHeader(title: "相关推荐").padding(.bottom, 2)
      ForEach(Array(related.enumerated()), id: \.element.id) { i, item in
        if i > 0 { Divider().padding(.leading, 158) }
        NavigationLink {
          SeasonView(
            season: .init(
              season_id: item.id, title: item.title ?? "", cover: item.cover ?? "",
              index_show: item.new_ep?.index_show))
        } label: {
          SeasonRelatedRow(item: item)
        }.buttonStyle(.plain)
      }
    }
  }
}

/// `/pgc/season/episode/web/info`: the playing episode's counters and the creators credited on it.
struct SeasonEpisodeFacts: Decodable {
  struct Stat: Decodable { let like: Int64?, coin: Int64?, favorite: Int64?, share: Int64? }
  struct Up: Decodable, Identifiable {
    let mid: Int64?, uname: String?, avatar: String?, is_follow: Int?
    var id: Int64 { mid ?? 0 }
  }
  let stat: Stat?
  let related_up: [Up]?
}

/// `/pgc/season/web/related/recommend`: shows like this one, as listed under the official intro.
struct SeasonRelatedPage: Decodable {
  struct Item: Decodable, Identifiable {
    struct Latest: Decodable { let cover: String?, index_show: String? }
    struct Rating: Decodable { let score: Double?, count: Int64? }
    struct Stat: Decodable { let view: Int64?, follow: Int64? }
    let season_id: Int64?, title: String?, cover: String?, badge: String?, rcmd_reason: String?
    let new_ep: Latest?, rating: Rating?, stat: Stat?
    var id: Int64 { season_id ?? 0 }
  }
  let season: [Item]?
}

/// A section title with an optional grey summary and chevron that opens the whole section.
private struct SeasonSectionHeader: View {
  let title: String
  var trailing: String? = nil
  var action: (() -> Void)? = nil
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title).font(.body.weight(.medium))
      Spacer(minLength: 8)
      if let action {
        Button {
          TouchFeedback.light()
          action()
        } label: {
          HStack(spacing: 2) {
            if let trailing { Text(trailing).lineLimit(1) }
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
          }
          .font(.footnote).foregroundStyle(.secondary)
          .frame(minHeight: 30).contentShape(Rectangle())
        }.buttonStyle(.plain)
      } else if let trailing {
        Text(trailing).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
      }
    }
  }
}

/// The blue 出品 / 独家 tag after the title (pink for member-only shows).
private struct SeasonBadgeTag: View {
  let text: String
  var body: some View {
    let tint = text.contains("会员") ? Color.pink : Color(red: 0.0, green: 0.6, blue: 0.86)
    Text(text).font(.caption2.weight(.semibold)).foregroundStyle(tint)
      .padding(.horizontal, 5).padding(.vertical, 2)
      .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
      .fixedSize()
  }
}

/// The pink corner tag (会员, 预告) on an episode card or a cover.
private struct SeasonCornerBadge: View {
  let text: String
  var corner: CGFloat = 8
  var body: some View {
    Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
      .padding(.horizontal, 5).padding(.vertical, 2)
      .background(
        Color.pink,
        in: UnevenRoundedRectangle(bottomLeadingRadius: 6, topTrailingRadius: corner, style: .continuous))
  }
}

enum SeasonEpisodeText {
  static func unit(_ type: Int?) -> String { type == 1 || type == 4 ? "话" : "集" }
  /// "第 197 话" for anime, "第 12 集" for drama; titles that are not numbers stay as they are.
  static func heading(_ e: SeasonInfo.Episode, type: Int?) -> String {
    guard Int(e.title) != nil else { return e.title.isEmpty ? e.label : e.title }
    return "第 " + e.title + " " + unit(type)
  }
  static func name(_ e: SeasonInfo.Episode) -> String {
    let long = (e.long_title ?? "").trimmingCharacters(in: .whitespaces)
    return long.isEmpty ? (e.showTitle ?? e.label) : long
  }
  /// The whole title of an extra (花絮, PV): its title and subtitle together.
  static func full(_ e: SeasonInfo.Episode) -> String {
    if let show = e.showTitle, !show.isEmpty { return show }
    return [e.title, e.long_title ?? ""].map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }.joined(separator: " ")
  }
  static func duration(_ e: SeasonInfo.Episode) -> String? {
    // Season episodes carry their length in milliseconds.
    guard let d = e.duration, d > 0 else { return nil }
    return clockText(Double(d) / 1000)
  }
}

/// One episode as the official cards draw it: "第 71 话" over its title on a grey card, the
/// playing one in the accent colour, 会员 in the corner.
struct SeasonEpisodeCard: View {
  let episode: SeasonInfo.Episode
  let type: Int?
  let selected: Bool
  var busy = false
  let action: () -> Void
  var body: some View {
    let playable = episode.catalogPlayable
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    Button(action: action) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 4) {
          if selected {
            Image(systemName: "waveform").font(.caption.weight(.bold))
              .symbolEffect(.variableColor.iterative, options: .repeating)
          }
          Text(SeasonEpisodeText.heading(episode, type: type)).lineLimit(1)
          Spacer(minLength: 0)
          if busy { ProgressView().controlSize(.mini) }
        }
        Text(SeasonEpisodeText.name(episode)).lineLimit(1)
      }
      .font(.subheadline)
      .foregroundStyle(selected ? Color.accentColor : (playable ? Color.primary : Color.secondary))
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
      .background(Color(uiColor: .secondarySystemBackground), in: shape)
      .overlay(alignment: .topTrailing) {
        if let badge = episode.badge, !badge.isEmpty { SeasonCornerBadge(text: badge) }
      }
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(episode.label)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// Plays an entry from a strip or a panel, one at a time, keeping the failure to show it.
@MainActor private func seasonPick(
  _ e: SeasonInfo.Episode, current: Int64, busy: Binding<Int64?>, issue: Binding<String?>,
  pick: @escaping @MainActor (SeasonInfo.Episode) async throws -> Void, done: (@MainActor () -> Void)? = nil
) {
  guard e.id != current, e.catalogPlayable, busy.wrappedValue == nil else { return }
  TouchFeedback.light()
  busy.wrappedValue = e.id
  issue.wrappedValue = nil
  Task { @MainActor in
    defer { busy.wrappedValue = nil }
    do {
      try await pick(e)
      done?()
    } catch {
      if !Task.isCancelled { issue.wrappedValue = error.localizedDescription }
    }
  }
}

/// The intro's 选集 row, scrolled to the playing episode.
struct SeasonEpisodeStrip: View {
  let episodes: [SeasonInfo.Episode]
  let current: Int64
  let type: Int?
  let pick: @MainActor (SeasonInfo.Episode) async throws -> Void
  @State private var busy: Int64?
  @State private var issue: String?
  @State private var position: Int64?
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // The strip's own position, not ScrollViewReader: scrollTo also moves the scrollers
      // around it (the intro and the 简介/评论 pager).
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 10) {
          ForEach(episodes) { e in
            SeasonEpisodeCard(episode: e, type: type, selected: e.id == current, busy: busy == e.id) {
              seasonPick(e, current: current, busy: $busy, issue: $issue, pick: pick)
            }
            .frame(width: 150).id(e.id)
          }
        }.padding(.horizontal, 16).scrollTargetLayout()
      }
      .scrollPosition(id: $position, anchor: .center)
      .scrollClipDisabled().padding(.horizontal, -16)
      .frame(height: 64)
      .onAppear { if holds(current) { position = current } }
      .onChange(of: current) { _, id in
        if holds(id) { withAnimation(.snappy) { position = id } }
      }
      if let issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
    }
  }
  private func holds(_ id: Int64) -> Bool { episodes.contains { $0.id == id } }
}

/// A thumbnail with the length in its corner, as the official extra and related rows show.
private struct SeasonThumb: View {
  let url: URL?
  var duration: String? = nil
  var badge: String? = nil
  let width: CGFloat
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    SiteThumbnail(url: url) { $0.resizable().scaledToFill() } placeholder: {
      Color(uiColor: .secondarySystemFill)
    }
    .frame(width: width, height: (width * 9 / 16).rounded())
    .clipShape(shape)
    .overlay(alignment: .bottomTrailing) {
      if let duration {
        Text(duration).font(.caption2.weight(.medium)).monospacedDigit().foregroundStyle(.white)
          .padding(.horizontal, 4).padding(.vertical, 1)
          .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
          .padding(5)
      }
    }
    .overlay(alignment: .topTrailing) {
      if let badge, !badge.isEmpty { SeasonCornerBadge(text: badge, corner: 6) }
    }
  }
}

/// The extra section's row in the intro: thumbnails with the title below.
private struct SeasonExtraStrip: View {
  let episodes: [SeasonInfo.Episode]
  let current: Int64
  let pick: @MainActor (SeasonInfo.Episode) async throws -> Void
  @State private var busy: Int64?
  @State private var issue: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(alignment: .top, spacing: 10) {
          ForEach(episodes) { e in
            let selected = e.id == current
            Button {
              seasonPick(e, current: current, busy: $busy, issue: $issue, pick: pick)
            } label: {
              VStack(alignment: .leading, spacing: 6) {
                SeasonThumb(url: e.cover.flatMap(httpsURL), duration: SeasonEpisodeText.duration(e), width: 150)
                  .overlay { if busy == e.id { ProgressView().tint(.white) } }
                Text(SeasonEpisodeText.full(e)).font(.subheadline).lineLimit(2)
                  .multilineTextAlignment(.leading)
                  .foregroundStyle(selected ? Color.accentColor : Color.primary)
                  .frame(width: 150, alignment: .topLeading)
              }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(e.label)
            .accessibilityAddTraits(selected ? .isSelected : [])
          }
        }.padding(.horizontal, 16)
      }
      .scrollClipDisabled().padding(.horizontal, -16)
      if let issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
    }
  }
}

/// "1-50 51-100": the official panels split long lists into pages of fifty.
private struct SeasonRangeChips: View {
  let count: Int
  @Binding var selection: Int
  static let size = 50
  static func pages(_ count: Int) -> [Range<Int>] {
    stride(from: 0, to: count, by: size).map { $0..<min($0 + size, count) }
  }
  var body: some View {
    let pages = Self.pages(count)
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(pages.indices, id: \.self) { i in
          let on = i == selection
          Button {
            selection = i
          } label: {
            // The official pagination chip: 13 pt, medium when chosen, 4 pt corners.
            Text("\(pages[i].lowerBound + 1)-\(pages[i].upperBound)")
              .font(.footnote.weight(on ? .medium : .regular)).monospacedDigit()
              .foregroundStyle(on ? Color.accentColor : Color.secondary)
              .padding(.horizontal, 10).padding(.vertical, 6)
              .background(
                on ? Color.accentColor.opacity(0.1) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(on ? .isSelected : [])
        }
      }.padding(.horizontal, 16)
    }
  }
}

/// Sideways pages that follow the finger, as the official panels' pagers do. Past the first page
/// a right swipe turns back a page instead of closing the panel.
private struct SeasonPager<Page: View>: View {
  let count: Int
  @Binding var page: Int
  @ViewBuilder let content: (Int) -> Page
  @State private var position: Int?
  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(spacing: 0) {
        ForEach(0..<count, id: \.self) { i in
          content(i).containerRelativeFrame([.horizontal, .vertical]).id(i)
        }
      }.scrollTargetLayout()
    }
    .scrollTargetBehavior(.paging)
    .scrollPosition(id: $position)
    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    .onAppear { if position == nil { position = page } }
    .onChange(of: position) { _, p in if let p, p != page { page = p } }
    .onChange(of: page) { _, p in
      if position != p { withAnimation(.smooth(duration: 0.3)) { position = p } }
    }
    .preference(key: ReplyPanelSwipeLock.self, value: page > 0)
  }
}

/// The full 选集 panel: the update line, pages of fifty (tap a range or swipe) and a two-column
/// grid of cards.
struct SeasonEpisodeGrid: View {
  let episodes: [SeasonInfo.Episode]
  let current: Int64
  let type: Int?
  let summary: String?
  let pick: @MainActor (SeasonInfo.Episode) async throws -> Void
  @State private var playing: Int64?
  @State private var page: Int?
  @State private var busy: Int64?
  @State private var issue: String?
  var body: some View {
    let now = playing ?? current
    let pages = SeasonRangeChips.pages(episodes.count)
    let start = episodes.firstIndex(where: { $0.id == now }).map { $0 / SeasonRangeChips.size } ?? 0
    let selected = Binding(get: { page ?? start }, set: { page = $0 })
    VStack(alignment: .leading, spacing: 10) {
      if let summary, !summary.isEmpty {
        Text(summary).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
      }
      if pages.count > 1 { SeasonRangeChips(count: episodes.count, selection: selected) }
      if let issue { Text(issue).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16) }
      SeasonPager(count: pages.count, page: selected) { i in
        SeasonGridPage(
          episodes: Array(episodes[pages[i]]), now: now, type: type, busy: busy,
          focus: i == start ? current : nil
        ) { e in
          seasonPick(e, current: now, busy: $busy, issue: $issue, pick: pick) { playing = e.id }
        }
      }
    }
    .padding(.top, 12)
  }
}

/// One page of the 选集 grid, opened on the playing episode.
private struct SeasonGridPage: View {
  let episodes: [SeasonInfo.Episode]
  let now: Int64
  let type: Int?
  let busy: Int64?
  let focus: Int64?
  let tap: (SeasonInfo.Episode) -> Void
  @State private var position: Int64?
  var body: some View {
    ScrollView {
      LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
        ForEach(episodes) { e in
          SeasonEpisodeCard(episode: e, type: type, selected: e.id == now, busy: busy == e.id) { tap(e) }
            .id(e.id)
        }
      }
      .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 24)
      .scrollTargetLayout()
    }
    .scrollPosition(id: $position, anchor: .center)
    .onAppear { if position == nil, let focus { position = focus } }
  }
}

/// The extra sections in full: their titles as tabs, pages of fifty, a thumbnail list. Every
/// (section, range) page sits in one sideways pager, so a swipe runs on from a section's last
/// range into the next section, and the tabs and ranges follow it.
private struct SeasonExtrasPanel: View {
  let groups: [SeasonInfo.CatalogGroup]
  let current: Int64
  let pick: @MainActor (SeasonInfo.Episode) async throws -> Void
  @State private var page: Int
  @State private var playing: Int64?
  @State private var busy: Int64?
  @State private var issue: String?
  private struct Slot { let group: Int, range: Int, rows: Range<Int> }
  private let slots: [Slot]
  init(
    groups: [SeasonInfo.CatalogGroup], start: Int, current: Int64,
    pick: @escaping @MainActor (SeasonInfo.Episode) async throws -> Void
  ) {
    self.groups = groups
    self.current = current
    self.pick = pick
    var list = [Slot]()
    for (g, group) in groups.enumerated() {
      for (r, rows) in SeasonRangeChips.pages(group.episodes.count).enumerated() {
        list.append(.init(group: g, range: r, rows: rows))
      }
    }
    slots = list
    let first = list.firstIndex { $0.group == start } ?? 0
    _page = State(initialValue: first)
  }
  var body: some View {
    let now = playing ?? current
    let slot = slots.isEmpty ? nil : slots[min(page, slots.count - 1)]
    let group = slot?.group ?? 0
    let tab = Binding(
      get: { group },
      set: { g in if let i = slots.firstIndex(where: { $0.group == g }) { page = i } })
    let range = Binding(
      get: { slot?.range ?? 0 },
      set: { r in if let i = slots.firstIndex(where: { $0.group == group && $0.range == r }) { page = i } })
    VStack(alignment: .leading, spacing: 10) {
      if groups.count > 1 {
        UnderlineTabBar(items: Array(groups.indices), selection: tab, title: { groups[$0].title }, fill: false)
      }
      if !groups.isEmpty, groups[group].episodes.count > SeasonRangeChips.size {
        SeasonRangeChips(count: groups[group].episodes.count, selection: range).id(group)
      }
      if let issue { Text(issue).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16) }
      SeasonPager(count: slots.count, page: $page) { i in
        let s = slots[i]
        SeasonExtrasPage(episodes: Array(groups[s.group].episodes[s.rows]), now: now, busy: busy) { e in
          seasonPick(e, current: now, busy: $busy, issue: $issue, pick: pick) { playing = e.id }
        }
      }
    }
    .padding(.top, 6)
  }
}

private struct SeasonExtrasPage: View {
  let episodes: [SeasonInfo.Episode]
  let now: Int64
  let busy: Int64?
  let tap: (SeasonInfo.Episode) -> Void
  var body: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(Array(episodes.enumerated()), id: \.element.id) { i, e in
          if i > 0 { Divider().padding(.leading, 16) }
          let selected = e.id == now
          Button {
            tap(e)
          } label: {
            HStack(alignment: .top, spacing: 12) {
              SeasonThumb(url: e.cover.flatMap(httpsURL), duration: SeasonEpisodeText.duration(e), width: 146)
                .overlay { if busy == e.id { ProgressView().tint(.white) } }
              Text(SeasonEpisodeText.full(e)).font(.subheadline).lineLimit(3)
                .multilineTextAlignment(.leading)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
              Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 10).contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(e.label)
          .accessibilityAddTraits(selected ? .isSelected : [])
        }
      }.padding(.bottom, 24)
    }
  }
}

/// A related show: wide cover, title and score, the reason and episode count, plays and follows.
private struct SeasonRelatedRow: View {
  let item: SeasonRelatedPage.Item
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      SeasonThumb(url: (item.new_ep?.cover ?? item.cover).flatMap(httpsURL), badge: item.badge, width: 146)
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .top, spacing: 6) {
          Text(item.title ?? "").font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
          if let score = item.rating?.score, score > 0 {
            VStack(alignment: .trailing, spacing: 0) {
              Text(score.formatted(.number.precision(.fractionLength(1))) + "分")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
              if let n = item.rating?.count, n > 0 {
                Text(n.formatted(.number.notation(.compactName)) + "人").font(.caption2).foregroundStyle(.secondary)
              }
            }
          }
        }
        Spacer(minLength: 0)
        HStack(spacing: 6) {
          if let reason = item.rcmd_reason, !reason.isEmpty {
            Text(reason).font(.caption2).foregroundStyle(.orange)
              .padding(.horizontal, 4).padding(.vertical, 1)
              .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
          }
          if let show = item.new_ep?.index_show, !show.isEmpty {
            Text(show).font(.caption).foregroundStyle(.secondary)
          }
        }.lineLimit(1)
        HStack(spacing: 10) {
          if let n = item.stat?.view, n > 0 { SeasonIntro.counter("play.rectangle", n) }
          if let n = item.stat?.follow, n > 0 { SeasonIntro.counter("heart", n) }
        }.font(.caption).foregroundStyle(.secondary)
      }
      .frame(height: 82)
    }
    .padding(.vertical, 10).contentShape(Rectangle())
  }
}

/// 缓存 and 分享 after like / coin / favourite, as in the official app; 稍后再看 is in the share menu.
private struct SeasonActionColumns: View {
  let episode: SeasonInfo.Episode
  let seasonTitle: String?
  let seasonType: Int?
  @ObservedObject var model: PlayerModel
  let shares: Int64?
  @Binding var sharingMoment: MediaMomentSelection?
  @EnvironmentObject private var accounts: AccountContext
  @State private var later: Bool?
  @State private var busy = false
  @State private var notice: String?
  private var aid: Int64? { episode.aid ?? ArchiveNumber.av(episode.bvid) }
  var body: some View {
    NavigationLink { EpisodeCacheView(episode: episode, course: false) } label: {
      ArchiveActionColumn(symbol: "arrow.down.circle", title: "缓存", active: false)
    }
    .disabled(!episode.allowCacheEntry || model.isPreview)
    .accessibilityLabel("缓存本集")
    Menu {
      Button(
        later == true ? "移出稍后再看" : "稍后再看", systemImage: later == true ? "clock.fill" : "clock"
      ) { Task { await toggleLater() } }
      .disabled(busy || aid == nil)
      if let url = ArchiveSharePoint.episode(episode.id) {
        Section {
          ArchiveShareButtons(normal: url) {
            ArchiveSharePoint.episode(episode.id, time: model.engine.currentTime().seconds)
          }
          MediaMomentButton(
            resource: .episode(episode, category: seasonType, parent: seasonTitle), selection: $sharingMoment)
          IMShareButton(
            card: .init(
              .episode, id: String(episode.id), title: episode.share_copy ?? episode.label,
              thumb: episode.cover.flatMap(httpsURL), link: episode.share_url.flatMap(httpsURL)))
          NavigationLink {
            SharePoster(
              content: .init(
                title: seasonTitle ?? episode.label, body: episode.share_copy ?? episode.label, author: "",
                date: "", kind: "剧集", link: url, cover: episode.cover.flatMap(httpsURL)))
          } label: { Label("生成分享卡片", systemImage: "photo.on.rectangle") }
        }
      }
      if let cover = episode.cover.flatMap(httpsURL) {
        Button("保存封面", systemImage: "photo") {
          Task {
            do { _ = try await GalleryAssets().savePictures([.init(cover)]); notice = "封面已保存" }
            catch { notice = error.localizedDescription }
          }
        }
      }
    } label: {
      ArchiveActionColumn(
        symbol: "arrowshape.turn.up.right",
        title: shares.flatMap { $0 > 0 ? $0.formatted(.number.notation(.compactName)) : nil } ?? "分享",
        active: false)
    }
    .accessibilityLabel("分享")
    .alert("提示", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
      Button("好") {}
    } message: { Text(notice ?? "") }
  }
  @MainActor private func toggleLater() async {
    guard let uid = accounts.state.active else { notice = "请先登录"; return }
    guard let aid, !busy else { return }
    busy = true
    defer { busy = false }
    let adding = later != true
    do {
      let fields: [String: String] = adding
        ? (episode.bvid.isEmpty ? ["aid": String(aid)] : ["bvid": episode.bvid])
        : ["resources": String(aid)]
      try await BiliAPI.shared.submit(
        adding ? "/x/v2/history/toview/add" : "/x/v2/history/toview/v2/dels", fields, expectedAccount: uid)
      guard accounts.state.active == uid else { return }
      later = adding
      TouchFeedback.light()
      AppToast.show(adding ? "已加入稍后再看" : "已移出稍后再看")
    } catch { if accounts.state.active == uid { notice = error.localizedDescription } }
  }
}

/// 追番 / 已追番: a capsule like the original's tonal button; once followed it offers the watch
/// state and unfollowing.
struct SeasonFollowButton: View {
  let id: Int64
  var type: Int?
  @EnvironmentObject private var accounts: AccountContext
  @State private var status: SeasonFollow.Status?
  @State private var busy = false
  @State private var issue: String?
  private var noun: String { type == 1 || type == 4 ? "追番" : "追剧" }
  var body: some View {
    Group {
      if let owner = accounts.state.active {
        if status?.follow == 1 {
          Menu {
            Picker("观看状态", selection: Binding(
              get: { status?.follow_status ?? 2 }, set: { v in Task { await set(v, owner: owner) } })
            ) {
              Text("想看").tag(1)
              Text("在看").tag(2)
              Text("看过").tag(3)
            }
            Button("取消" + noun, role: .destructive) { Task { await set(0, owner: owner) } }
          } label: { capsule("已" + noun, followed: true) }
        } else {
          Button { Task { await set(-1, owner: owner) } } label: { capsule(noun, followed: false) }
            .buttonStyle(.plain)
        }
      }
    }
    .disabled(busy || (accounts.state.active != nil && status == nil && issue == nil))
    .task(id: "\(id):\(accounts.state.active ?? "")") {
      status = nil
      issue = nil
      if let owner = accounts.state.active { await load(owner) }
    }
    .alert("追番", isPresented: Binding(get: { issue != nil && status != nil }, set: { if !$0 { issue = nil } })) {
      Button("好") {}
    } message: { Text(issue ?? "") }
  }
  private func capsule(_ text: String, followed: Bool) -> some View {
    HStack(spacing: 4) {
      Image(systemName: followed ? "heart.fill" : "heart").font(.footnote.weight(.semibold))
      Text(text).font(.subheadline.weight(.medium))
    }
    .foregroundStyle(followed ? Color.secondary : Color.white)
    .padding(.horizontal, 12).frame(height: 32)
    .background(followed ? Color(uiColor: .tertiarySystemFill) : Color.accentColor, in: Capsule())
    .contentShape(Capsule())
  }
  private func load(_ owner: String) async {
    do {
      let next = try await BiliAPI.shared.read(
        "/pgc/view/web/season/user/status", ["season_id": "\(id)"], expectedAccount: owner,
        as: SeasonFollow.Status.self)
      guard !Task.isCancelled, accounts.state.active == owner else { return }
      status = next
    } catch {
      if !Task.isCancelled && accounts.state.active == owner { issue = error.localizedDescription }
    }
  }
  private func set(_ target: Int, owner: String) async {
    guard !busy, accounts.state.active == owner else { return }
    busy = true
    defer { busy = false }
    var f = ["season_id": "\(id)"]
    if target > 0 { f["status"] = "\(target)" }
    do {
      try await BiliAPI.shared.submit(
        "/pgc/web/follow/" + (target < 0 ? "add" : target == 0 ? "del" : "status/update"), f,
        expectedAccount: owner)
      TouchFeedback.light()
      await load(owner)
    } catch {
      if !Task.isCancelled && accounts.state.active == owner { issue = error.localizedDescription }
    }
  }
}

/// The full detail a tap on the intro opens (the original's intro_detail sheet): poster and
/// score, the synopsis, facts, cast and staff, tags, reviews and batch caching.
struct SeasonDetailSheet: View {
  let info: SeasonInfo
  let tags: [SeasonCatalogView.Tag]
  let current: SeasonInfo.Episode
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    PiliNavigationStack {
      List {
        Section {
          HStack(alignment: .top, spacing: 14) {
            if let url = info.cover.flatMap(httpsURL) {
              GalleryLink([.init(url)], index: 0) {
                SiteThumbnail(url: url) { $0.resizable().scaledToFill() } placeholder: {
                  Color(uiColor: .secondarySystemFill)
                }
                .frame(width: 90, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
              }.buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 6) {
              Text(info.title).font(.headline).textSelection(.enabled)
              if let score = info.rating?.score, score > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                  Text(score.formatted(.number.precision(.fractionLength(1))))
                    .font(.title2.weight(.bold)).foregroundStyle(.orange)
                  if let n = info.rating?.count, n > 0 {
                    Text(n.formatted(.number.notation(.compactName)) + "人评分")
                      .font(.caption).foregroundStyle(.secondary)
                  }
                }
              }
              if let stat = info.stat {
                Text([
                  stat.views.map { $0.formatted(.number.notation(.compactName)) + "播放" },
                  stat.danmakus.map { $0.formatted(.number.notation(.compactName)) + "弹幕" },
                  stat.favorites.map { $0.formatted(.number.notation(.compactName)) + "追番" },
                ].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
              }
              if let update = info.new_ep?.desc, !update.isEmpty {
                Text(update).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          .padding(.vertical, 4)
        }
        if let text = info.evaluate, !text.isEmpty {
          Section("简介") {
            Text(text).font(.subheadline).lineSpacing(3).textSelection(.enabled)
          }
        }
        let facts = (info.areas ?? []).compactMap(\.name) + [info.publish?.pub_time_show].compactMap { $0 }
        if !facts.isEmpty || !(info.jp_title ?? "").isEmpty || !(info.alias ?? "").isEmpty {
          Section("作品信息") {
            if !facts.isEmpty { Text(facts.joined(separator: " · ")).font(.subheadline) }
            if let original = info.jp_title, !original.isEmpty, original != info.title {
              LabeledContent("原名", value: original).textSelection(.enabled)
            }
            if let alias = info.alias, !alias.isEmpty {
              LabeledContent("别名", value: alias).textSelection(.enabled)
            }
          }
        }
        if let actors = info.actors, !actors.isEmpty {
          Section("角色声优") { Text(actors).font(.subheadline).lineSpacing(3).textSelection(.enabled) }
        }
        if let staff = info.staff, !staff.isEmpty {
          Section("制作信息") { Text(staff).font(.subheadline).lineSpacing(3).textSelection(.enabled) }
        }
        let names = Array(Set((info.styles ?? []).filter { !$0.isEmpty } + tags.map(\.tag_name))).sorted()
        if !names.isEmpty {
          Section("标签") {
            WrappingActions(spacing: 8, rowSpacing: 8) {
              ForEach(names, id: \.self) { name in
                NavigationLink { SearchView(keyword: name) } label: {
                  Text(name).font(.subheadline).foregroundStyle(.primary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                }.buttonStyle(.plain)
              }
            }.padding(.vertical, 4)
          }
        }
        Section {
          if let media = info.media_id, media > 0 {
            NavigationLink {
              SeasonReviews(media: media, publishing: info.rights?.allow_review != 0)
            } label: { Label("点评", systemImage: "star.bubble") }
          }
          if let up = info.up_info, let uid = up.mid, uid > 0 {
            NavigationLink { CreatorSpace(mid: uid, name: up.uname ?? "出品方") } label: {
              Label(up.uname ?? "出品方", systemImage: "person.crop.circle")
            }
          }
          if let group = info.groups.first(where: { g in g.episodes.contains { $0.id == current.id } }),
            group.episodes.lazy.filter(\.allowCacheEntry).prefix(2).count > 1
          {
            NavigationLink {
              SeasonBatchCache(episodes: group.episodes, course: false, title: group.title)
            } label: { Label("批量缓存", systemImage: "arrow.down.circle") }
          }
        }
      }
      .listStyle(.insetGrouped).listSectionSpacing(12)
      .navigationTitle("作品详情").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
  }
}
