import Observation
import SwiftUI

/// The sheets, dialogs and alerts behind a video card's long-press menu. One host per
/// navigation stack presents them for every card on its pages: each card used to carry three
/// sheets, a dialog, two alerts and eight states of its own, which made long feeds expensive
/// to scroll and to switch to.
@MainActor @Observable final class ArchiveCoverHost {
  enum Sheet: Identifiable {
    case cover(URL), creator(Int64, String), summary(Video, Int64)
    var id: String {
      switch self {
      case .cover(let u): "cover:" + u.absoluteString
      case .creator(let mid, _): "creator:\(mid)"
      case .summary(let v, let cid): "summary:\(v.bvid):\(cid)"
      }
    }
  }
  struct Block: Identifiable {
    let id = UUID()
    let video: Video, mid: Int64, owner: String?
    let remove: ((DiscoveryCardRemoval) -> Void)?
  }
  struct Dislike {
    let video: Video, aid: Int64, owner: String
    let remove: ((DiscoveryCardRemoval) -> Void)?
  }
  var sheet: Sheet?
  var block: Block?
  var undo: Dislike?
  var result: String?
  @ObservationIgnored private var saving = false

  func run(_ text: String, _ work: @escaping @MainActor () async throws -> Void) {
    guard !saving else { return }
    saving = true
    Task { @MainActor in
      defer { saving = false }
      do {
        try await work()
        result = text
      } catch { result = error.localizedDescription }
    }
  }
  func dislike(_ request: Dislike, undo isUndo: Bool, accounts: AccountContext) {
    guard !saving, accounts.state.active == request.owner else { return }
    saving = true
    Task { @MainActor in
      defer { saving = false }
      do {
        try await BiliAPI.shared.archiveDislike(request.aid, undo: isUndo, owner: request.owner)
        guard accounts.state.active == request.owner else { return }
        if isUndo { result = "已撤销点踩" } else { undo = request }
      } catch { if accounts.state.active == request.owner { result = error.localizedDescription } }
    }
  }
  func hideCreator(_ mid: Int64, video: Video, remove: ((DiscoveryCardRemoval) -> Void)?) throws {
    var rules = RecommendationRules.current()
    rules.blockedCreators.insert(mid)
    try rules.save()
    remove?(.init(archive: video.bvid, creator: mid))
  }
}

private struct ArchiveCoverHostKey: EnvironmentKey { static let defaultValue: ArchiveCoverHost? = nil }
extension EnvironmentValues {
  var archiveCoverHost: ArchiveCoverHost? {
    get { self[ArchiveCoverHostKey.self] }
    set { self[ArchiveCoverHostKey.self] = newValue }
  }
}

/// Presents what card menus below it request. Attach outside a navigation stack, so the
/// presentations work whichever page of the stack is showing.
struct ArchiveCoverPresenter: ViewModifier {
  @State private var host = ArchiveCoverHost()
  func body(content: Content) -> some View {
    content.environment(\.archiveCoverHost, host).modifier(ArchiveCoverPresentations(host: host))
  }
}
private struct ArchiveCoverPresentations: ViewModifier {
  let host: ArchiveCoverHost
  @EnvironmentObject private var accounts: AccountContext
  func body(content: Content) -> some View {
    @Bindable var host = host
    content
      .piliSheet(item: $host.sheet) { sheet in
        PiliNavigationStack {
          Group {
            switch sheet {
            case .cover(let url): NativeGallery([.init(url)])
            case .creator(let mid, let name): CreatorSpace(mid: mid, name: name)
            case .summary(let video, let cid): CardVideoSummary(video: video, cid: cid)
            }
          }.toolbar { Button("完成") { host.sheet = nil } }
        }
      }
      .confirmationDialog(
        "屏蔽 " + (host.block?.video.owner?.name ?? "UP 主") + "？",
        isPresented: Binding(get: { host.block != nil }, set: { if !$0 { host.block = nil } }),
        titleVisibility: .visible, presenting: host.block
      ) { request in
        Button("仅在本机屏蔽") {
          host.run("已在本机屏蔽") { try host.hideCreator(request.mid, video: request.video, remove: request.remove) }
        }
        if let uid = request.owner, uid == accounts.state.active {
          Button("加入账号黑名单", role: .destructive) {
            host.run("已加入黑名单") {
              try await BiliAPI.shared.submit(
                "/x/relation/modify", ["fid": String(request.mid), "act": "5", "re_src": "11"],
                expectedAccount: uid)
              if accounts.state.active == uid { request.remove?(.init(archive: request.video.bvid, creator: request.mid)) }
            }
          }
        }
      }
      .alert(
        "已点踩", isPresented: Binding(get: { host.undo != nil }, set: { if !$0 { host.undo = nil } }),
        presenting: host.undo
      ) { request in
        Button("撤销") {
          if request.owner == accounts.state.active { host.dislike(request, undo: true, accounts: accounts) }
        }
        Button("完成") {
          if request.owner == accounts.state.active { request.remove?(.init(archive: request.video.bvid, creator: nil)) }
        }
      }
      .alert("视频", isPresented: Binding(get: { host.result != nil }, set: { if !$0 { host.result = nil } })) {
        Button("好") {}
      } message: {
        Text(host.result ?? "")
      }
  }
}

private struct ArchiveCoverMenu<Extra: View>: ViewModifier {
  let video: Video, extra: Extra
  @Environment(\.archiveCoverHost) private var host
  func body(content: Content) -> some View {
    if let host {
      content.contextMenu { ArchiveCoverItems(video: video, host: host, extra: extra) }
    } else {
      content.modifier(ArchiveCoverLocalHost(video: video, extra: extra))
    }
  }
}

/// The menu itself; a separate view so the card only rebuilds it when the menu opens.
private struct ArchiveCoverItems<Extra: View>: View {
  let video: Video, host: ArchiveCoverHost, extra: Extra
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.discoveryCardRemoval) private var remove
  @AppStorage("detail.summary") private var summaryEnabled = false
  private var archiveID: Int64? { video.aid ?? ArchiveNumber.av(video.bvid) }
  private var mid: Int64? { video.owner?.mid.flatMap { $0 > 0 ? $0 : nil } }
  var body: some View {
    if ArchiveNumber.av(video.bvid) != nil {
      Button("复制 BV 号", systemImage: "doc.on.doc") { UIPasteboard.general.string = video.bvid }
    }
    if let mid {
      Button("访问 " + (video.owner?.name ?? "UP 主"), systemImage: "person.crop.circle") {
        host.sheet = .creator(mid, video.owner?.name ?? "UP 主")
      }
    }
    if summaryEnabled, let cid = video.cid, cid > 0, ArchiveNumber.av(video.bvid) != nil {
      Button("视频总结", systemImage: "text.quote") { host.sheet = .summary(video, cid) }
    }
    if let mid, accounts.state.active != String(mid) {
      Button("屏蔽 UP 主", systemImage: "person.slash") {
        host.block = .init(video: video, mid: mid, owner: accounts.state.active, remove: remove)
      }
    }
    if video.recommendGoto == nil, let uid = accounts.state.active, let aid = archiveID, aid > 0 {
      Menu("不感兴趣", systemImage: "hand.thumbsdown") {
        Button("点踩") { host.dislike(.init(video: video, aid: aid, owner: uid, remove: remove), undo: false, accounts: accounts) }
        Button("撤销点踩") { host.dislike(.init(video: video, aid: aid, owner: uid, remove: remove), undo: true, accounts: accounts) }
      }
    }
    if let cover = video.cover {
      Button("查看封面", systemImage: "photo") { host.sheet = .cover(cover) }
      Button("保存封面", systemImage: "square.and.arrow.down") {
        host.run("封面已保存") { _ = try await GalleryAssets().savePictures([.init(cover)]) }
      }
      Button("复制封面地址", systemImage: "doc.on.doc") { UIPasteboard.general.url = cover }
    }
    if let uid = accounts.state.active, let aid = archiveID {
      Button("添加到稍后再看", systemImage: "clock") {
        host.run("已加入稍后再看") {
          try await BiliAPI.shared.submit("/x/v2/history/toview/add", ["aid": String(aid)], expectedAccount: uid)
        }
      }
    }
    extra
  }
}

/// Cards outside any navigation stack (the fullscreen player's drawer) keep their own host.
private struct ArchiveCoverLocalHost<Extra: View>: ViewModifier {
  let video: Video, extra: Extra
  @State private var host = ArchiveCoverHost()
  func body(content: Content) -> some View {
    content.contextMenu { ArchiveCoverItems(video: video, host: host, extra: extra) }
      .modifier(ArchiveCoverPresentations(host: host))
  }
}

/// A list row's "⋮": the same menu as a card's long press, from a button.
struct ArchiveCoverMoreButton<Label: View>: View {
  let video: Video
  @ViewBuilder let label: () -> Label
  @Environment(\.archiveCoverHost) private var host
  @State private var local = ArchiveCoverHost()
  var body: some View {
    if let host {
      Menu { ArchiveCoverItems(video: video, host: host, extra: EmptyView()) } label: { label() }
        .accessibilityLabel("更多")
    } else {
      Menu { ArchiveCoverItems(video: video, host: local, extra: EmptyView()) } label: { label() }
        .accessibilityLabel("更多")
        .modifier(ArchiveCoverPresentations(host: local))
    }
  }
}

extension View {
  func archiveCover<Extra: View>(_ video: Video, @ViewBuilder extra: () -> Extra) -> some View {
    modifier(ArchiveCoverMenu(video: video, extra: extra()))
  }
  func archiveCover(_ video: Video) -> some View { archiveCover(video) { EmptyView() } }
}
