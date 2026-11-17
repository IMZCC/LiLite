import CryptoKit
import SwiftUI

extension CloudEntry {
  var libraryPoint: ArchiveStart? {
    if case .later(let m) = self, let cid = m.cid, cid > 0, let t = m.progress, t != 0 {
      return .init(cid: cid, seconds: Double(max(0, t)))
    }
    return nil
  }
  var queueTarget: SharedLink? {
    switch self {
    case .sharedItem(let r):
      guard r.sharedSelectable else { return nil }
      if let ep = r.sharedEpisode { return .episode(ep) }
      return r.genuineBV.map { .video($0, nil) }
    case .video(let v): return v.bvid.isEmpty ? nil : .video(v.bvid, nil)
    case .later(let l):
      switch l.route {
      case .episode(let e): return .episode(e)
      case .video(let b, let p): return .video(b, p)
      default: return nil
      }
    case .favorite(let f):
      switch f.route {
      case .video(let b, let p): return .video(b, p)
      case .archive(let a, let p): return ArchiveNumber.bv(a).map { .video($0, p) }
      case .episode(let e): return .episode(e)
      default: return nil
      }
    }
  }
  var queueSubtitle: String {
    let author: String?
    let seconds: Int?
    switch self {
    case .sharedItem(let r):
      author = r.upper?.name
      seconds = r.duration
    case .later(let l): return l.caption
    case .video(let v):
      author = v.owner?.name
      seconds = v.duration
    case .favorite(let f):
      author = f.upper?.name
      seconds = f.duration
    }
    return [author, seconds.map { clockText(Double($0)) }].compactMap { $0 }.filter { !$0.isEmpty }
      .joined(separator: " · ")
  }
  var queueCover: URL? {
    switch self {
    case .sharedItem(let r): r.cover.flatMap(httpsURL)
    case .later(let l): l.cover
    case .video(let v): v.cover
    case .favorite(let f): f.cover.flatMap(httpsURL)
    }
  }
}
enum LibraryPlaylistSignature {
  static func key(_ str: String) -> String {
    SHA256.hash(data: Data(str.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
struct LibraryPlaylist: View {
  let start: PlaylistStart, embedded: Bool
  @StateObject private var list: CloudPlaybackList
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.dismiss) private var dismiss
  @State private var panel = false
  @State private var didOpen = false
  @Environment(\.listenOrigin) private var parentListenOrigin
  private var listenOrigin: ListenOrigin? {
    switch list.kind {
    case .shared(let id, _): return .media(id, kind: 4)
    case .favorites(let f): return .favorites(f.id)
    case .creator(let s, let h):
      return s.listType(h).map { .media(s.source.business, kind: Int64($0)) }
    case .later: return Int64(list.uid).map { .media($0, kind: 2) }
    default: return parentListenOrigin
    }
  }
  init(
    kind: CloudLibraryKind, uid: String, query: String, order: FavoriteSort, viewed: Int,
    ascending: Bool, start: PlaylistStart, allowChanges: Bool = true, embedded: Bool = false
  ) {
    self.start = start
    self.embedded = embedded
    _list = StateObject(
      wrappedValue: .init(
        kind, uid: uid, term: query, order: order, viewed: viewed, ascending: ascending,
        allowChanges: allowChanges))
  }
  static func hasCreatorMark(_ s: CreatorArchiveScope) -> Bool {
    guard PlaybackMemory.enabled else { return false }
    return CloudPlaybackList.marks()[
      CloudPlaybackList.makeKey(
        .creator(s, nil), uid: s.owners.main, term: "", order: .mtime, viewed: 0, ascending: false)]
      != nil
  }
  @ViewBuilder private func container<Content: View>(@ViewBuilder content: () -> Content)
    -> some View
  {
    if embedded { content() } else { PiliNavigationStack { content() } }
  }
  var body: some View {
    container {
      Group {
        if let slot = list.current, let dest = slot.item.queueTarget {
          switch dest {
          case .video(let b, let p):
            DetailView(
              initial: .preview(
                id: b, title: slot.item.title, cover: slot.item.queueCover?.absoluteString ?? "",
                author: nil), initialPage: p, libraryPoint: list.point(slot),
              queueEnd: { await list.ended($0, $1) },
              queueStep: { await list.advance($0, fullscreen: $1) },
              resumeFullscreen: list.resumeFullscreen
            ).id(slot.item.id)
          case .episode(let id):
            EpisodeLink(
              id: id, queueEnd: { await list.ended($0, $1) },
              queueStep: { await list.advance($0, fullscreen: $1) },
              resumeFullscreen: list.resumeFullscreen
            ).id(slot.item.id)
          default: EmptyView()
          }
        } else if list.busy {
          ProgressView("读取播放列表")
        } else {
          ContentUnavailableView("暂无可播放内容", systemImage: "play.rectangle")
        }
      }.environment(
        \.libraryPlaybackPanel,
        LibraryQueuePresentation { full in AnyView(CloudInlineQueue(list: list, fullscreen: full)) }
      ).environment(\.listenOrigin, listenOrigin).safeAreaInset(edge: .bottom) {
        VStack {
          if let issue = list.issue {
            Text(issue).font(.caption).foregroundStyle(.secondary)
            if list.current == nil {
              Button("重试") { Task { await list.open(start) } }
              if start.resume || start.rowID != nil {
                Button("从头播放") { Task { await list.open(.init()) } }
              }
            }
          }
          HStack {
            Button {
              Task { _ = await list.advance(false) }
            } label: {
              Image(systemName: "backward.end").accessibilityLabel("上一条")
            }
            Spacer()
            Button {
              panel = true
            } label: {
              Label(list.kind.title, systemImage: "list.bullet")
            }.lineLimit(1)
            Spacer()
            Button {
              Task { _ = await list.advance(true) }
            } label: {
              Image(systemName: "forward.end").accessibilityLabel("下一条")
            }
          }.disabled(list.busy).padding(.horizontal)
        }.padding(.vertical, 7).background(.bar)
      }.toolbar {
        if !embedded {
          ToolbarItem(placement: .cancellationAction) {
            Button("关闭") {
              list.invalidate()
              dismiss()
            }
          }
        }
      }
    }.task {
      if !didOpen {
        didOpen = true
        await list.open(start)
      }
    }.piliSheet(isPresented: $panel) { CloudQueuePanel(list: list) }
      .onChange(of: accounts.state.owner(list.kind.readingRole) ?? "") { _, uid in
        if uid != list.uid {
          list.invalidate()
          dismiss()
        }
      }
      .onChange(of: CreatorQueueOwners(accounts.state)) { _, scope in
        if let owners = list.kind.cursorOwners, owners != scope {
          list.invalidate()
          dismiss()
        }
      }.onDisappear { list.invalidate() }
  }
}
private struct CloudQueuePanel: View {
  @ObservedObject var list: CloudPlaybackList
  @Environment(\.dismiss) private var dismiss
  @State private var removal: CloudPlaybackList.Window.Slot?
  @State private var cover: GalleryPicture?
  var body: some View {
    PiliNavigationStack {
      ScrollViewReader { proxy in
        List {
          if list.missingPage(false) != nil { Button("加载前一页") { Task { await list.more(false) } } }
          ForEach(
            list.window.reversed ? Array(list.window.numbers.reversed()) : list.window.numbers,
            id: \.self
          ) { n in
            ForEach(list.window.slots(n), id: \.item.id) { slot in
              Button {
                if slot.item.queueTarget != nil {
                  list.select(slot)
                  dismiss()
                }
              } label: {
                MediaRow(cover: slot.item.queueCover, title: slot.item.title,
                  subtitle: slot.item.queueSubtitle, dimmed: slot.item.queueTarget == nil, thumbWidth: 120) {
                  if list.current?.item.id == slot.item.id {
                    Image(systemName: "waveform").foregroundStyle(.tint)
                      .symbolEffect(.variableColor.iterative, options: .repeating)
                      .accessibilityLabel("正在播放")
                  }
                }
              }.id(slot.item.id).foregroundStyle(
                slot.item.queueTarget == nil ? Color.secondary : Color.primary
              ).contextMenu {
                if let url = slot.item.queueCover {
                  Button("查看封面") { cover = GalleryPicture(url) }
                  ShareLink(item: url)
                }
              }
              .swipeActions(allowsFullSwipe: false) {
                if list.allowChanges { Button("移除", role: .destructive) { removal = slot } }
              }
            }
          }
          if list.missingPage(true) != nil { Button("加载后一页") { Task { await list.more(true) } } }
          if let issue = list.issue { Text(issue) }
        }.disabled(list.busy).onAppear {
          if let id = list.current?.item.id { proxy.scrollTo(id, anchor: .center) }
        }
      }.modifier(ReplyEdgeDismiss()).navigationTitle("播放列表").toolbar {
        Button(list.showsReversed ? "改为顺序" : "改为倒序") { Task { await list.reverse() } }
        Button("完成") { dismiss() }
      }.confirmationDialog(
        "从列表移除这条内容？",
        isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
        presenting: removal
      ) { s in
        Button("移除", role: .destructive) { Task { await list.remove(s) } }
      }
    }.piliSheet(isPresented: Binding(get: { cover != nil }, set: { if !$0 { cover = nil } })) {
      if let cover {
        PiliNavigationStack { NativeGallery([cover]).toolbar { Button("完成") { self.cover = nil } } }
      }
    }.presentationDetents([.medium, .large])
  }
}

private struct CloudInlineQueue: View {
  @ObservedObject var list: CloudPlaybackList
  let fullscreen: Bool
  @State private var removal: CloudPlaybackList.Window.Slot?
  var body: some View {
    List {
      Button(list.showsReversed ? "改为顺序" : "改为倒序") {
        Task { await list.reverse(fullscreen: fullscreen) }
      }
      if list.missingPage(false) != nil { Button("载入前面的内容") { Task { await list.more(false) } } }
      ForEach(
        list.window.reversed ? Array(list.window.numbers.reversed()) : list.window.numbers,
        id: \.self
      ) { n in
        ForEach(list.window.slots(n), id: \.item.id) { s in
          Button {
            list.select(s, fullscreen: fullscreen)
          } label: {
            HStack {
              Text(s.item.title).lineLimit(2)
              Spacer()
              if list.current?.item.id == s.item.id {
                Image(systemName: "speaker.wave.2.fill").accessibilityLabel("正在播放")
              }
            }
          }.disabled(s.item.queueTarget == nil)
            .swipeActions(allowsFullSwipe: false) {
              if list.allowChanges { Button("移除", role: .destructive) { removal = s } }
            }

        }
      }
      if list.missingPage(true) != nil { Button("载入后面的内容") { Task { await list.more(true) } } }
      if let issue = list.issue { Text(issue).font(.footnote) }
    }.disabled(list.busy).listStyle(.plain)
      .confirmationDialog(
        "从列表移除这条内容？",
        isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
        presenting: removal
      ) { s in
        Button("移除", role: .destructive) { Task { await list.remove(s, fullscreen: fullscreen) } }
      }
  }
}
struct LibraryQueuePresentation { let view: @MainActor (Bool) -> AnyView }
private struct LibraryPanelKey: EnvironmentKey {
  static let defaultValue: LibraryQueuePresentation? = nil
}
extension EnvironmentValues {
  var libraryPlaybackPanel: LibraryQueuePresentation? {
    get { self[LibraryPanelKey.self] }
    set { self[LibraryPanelKey.self] = newValue }
  }
}
struct JoinedPlaybackPanels: View {
  let queue: AnyView, episodes: AnyView
  @State private var parts = false
  var body: some View {
    VStack(spacing: 0) {
      ChipBar(items: [false, true], selection: $parts, title: { $0 ? "视频选集" : "当前队列" })
        .padding(.vertical, 6)
      if parts { episodes } else { queue }
    }
  }
  static func merge(_ provider: LibraryQueuePresentation?, _ episodes: AnyView?, fullscreen: Bool)
    -> AnyView?
  {
    let queue = provider?.view(fullscreen)
    if let queue, let episodes { return AnyView(Self(queue: queue, episodes: episodes)) }
    return queue ?? episodes
  }
}
