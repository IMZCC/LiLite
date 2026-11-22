import SwiftUI

/// Horizontal cards for multi-part videos, like the episode rails in Apple's TV app.
struct ArchivePartStrip: View {
  let pages: [Video.Part]
  let current: Int64?
  let descending: Bool
  let pick: (Int64) -> Void
  let reorder: () -> Void
  var body: some View {
    let order = descending ? Array(pages.reversed()) : pages
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text("选集").font(.headline)
        Text("共 \(pages.count) P").font(.footnote).foregroundStyle(.secondary)
        Spacer(minLength: 8)
        Button(action: reorder) {
          Label(descending ? "倒序" : "正序", systemImage: "arrow.up.arrow.down")
            .font(.footnote.weight(.medium))
        }.buttonStyle(.plain).foregroundStyle(.secondary)
      }
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          LazyHStack(spacing: 10) {
            ForEach(order) { part in
              let selected = part.cid == current
              Button { if !selected { TouchFeedback.light(); pick(part.cid) } } label: {
                VStack(alignment: .leading, spacing: 4) {
                  HStack(spacing: 4) {
                    if selected {
                      Image(systemName: "waveform").font(.caption2.weight(.bold))
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                    }
                    Text("P\(part.page)").font(.caption.weight(.semibold)).monospacedDigit()
                    if let d = part.duration, d > 0 {
                      Text(clockText(Double(d))).font(.caption2).monospacedDigit()
                        .foregroundStyle(.secondary)
                    }
                  }.foregroundStyle(selected ? Color.accentColor : Color.secondary)
                  Text(part.part).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                  Spacer(minLength: 0)
                }
                .frame(width: 148, height: 58, alignment: .topLeading)
                .padding(12)
                .background(
                  selected ? Color.accentColor.opacity(0.12) : Color(uiColor: .secondarySystemBackground),
                  in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
              }.buttonStyle(.plain).id(part.cid)
                .accessibilityLabel("P\(part.page) \(part.part)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
          }.padding(.horizontal, 16)
        }.scrollClipDisabled().padding(.horizontal, -16)
          .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
          .onChange(of: current) { _, id in
            if let id { withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) } }
          }
      }
    }
  }
}

/// Related videos under the intro, as the official client's: no heading, a hairline, then the
/// cards (IntroRelateRow).
struct ArchiveRelatedList: View {
  let bvid: String
  @EnvironmentObject private var accounts: AccountContext
  @AppStorage("detail.related") private var enabled = true
  @State private var items: [Video] = []
  @State private var failed = false
  @State private var loaded = false
  var body: some View {
    // Always keep a concrete container: an empty Group would never run the load task. Lazy, so
    // the forty rows (cover, link and menu each) are built as they scroll in, not all at once
    // with the page.
    LazyVStack(alignment: .leading, spacing: 0) {
      if enabled {
        Rectangle().fill(OfficialIntro.ga2).frame(height: 0.5).padding(.horizontal, OfficialIntro.d(12))
        if failed && items.isEmpty {
          Button("加载失败，点击重试") { failed = false; Task { await load() } }
            .officialFont(13).foregroundStyle(OfficialIntro.ga5)
            .frame(maxWidth: .infinity).padding(.vertical, 24)
        } else if !loaded {
          ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
        } else if items.isEmpty {
          Text("暂无相关视频").officialFont(13).foregroundStyle(OfficialIntro.ga5)
            .frame(maxWidth: .infinity).padding(.vertical, 24)
        }
        ForEach(items) { video in
          ArchiveRelatedRow(video: video)
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
    .task(id: "\(bvid):\(accounts.state.owner(.role(.recommend)) ?? "")") { await load() }
    .environment(\.discoveryCardRemoval, { change in
      items.removeAll { v in v.bvid == change.archive || (change.creator != nil && v.owner?.mid == change.creator) }
    })
  }
  @MainActor private func load() async {
    guard enabled else { items = []; return }
    let owner = accounts.state.owner(.role(.recommend)) ?? ""
    do {
      let list = try await BiliAPI.shared.read(
        "/x/web-interface/archive/related", ["bvid": bvid], expectedAccount: owner, as: [Video].self)
      guard !Task.isCancelled else { return }
      let filtering = Task.detached(priority: .userInitiated) {
        let policy = RecommendationFilter()
        return list.filter { !Task.isCancelled && policy.allows($0, from: .related) }
      }
      let filtered = await withTaskCancellationHandler { await filtering.value } onCancel: { filtering.cancel() }
      try Task.checkCancellation()
      items = filtered
      failed = false
      loaded = true
    } catch {
      if !Task.isCancelled { failed = true; loaded = true }
    }
  }
}

struct ArchiveRelatedRow: View {
  let video: Video
  var body: some View {
    LazyLink {
      DetailView(initial: video)
    } label: {
      IntroRelateRow(video: video)
    }.buttonStyle(PressPrefetchStyle { ArchiveDetailPrefetch.shared.warm(video.bvid) }).archiveCover(video)
      .overlay(alignment: .bottomTrailing) { IntroRelateRow.more(video) }
  }
}

/// Gives existing labelled buttons (cast, sleep timer) the same chip appearance.
struct ToolChipLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) { configuration.icon; configuration.title }
      .font(.footnote.weight(.medium)).foregroundStyle(.primary)
      .padding(.horizontal, 12).padding(.vertical, 8)
      .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
      .contentShape(Capsule())
  }
}
/// Text chips for secondary tools, kept on one horizontally scrolling line.
struct ArchiveToolChip: View {
  let title: String, symbol: String
  var body: some View {
    Label(title, systemImage: symbol).font(.footnote.weight(.medium))
      .padding(.horizontal, 12).padding(.vertical, 8)
      .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
      .contentShape(Capsule())
  }
}
