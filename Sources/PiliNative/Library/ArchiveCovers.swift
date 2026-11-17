import SwiftUI

private struct ArchiveCoverMenu<Extra: View>: ViewModifier {
  let video: Video, extra: Extra
  @State private var preview = false
  @State private var saving = false
  @State private var result: String?
  @State private var previewCreator = false
  @State private var previewSummary = false
  @State private var block = false
  @State private var requestOwner: String?
  @State private var dislikeUndo = false
  @AppStorage("detail.summary") private var summaryEnabled = false
  @Environment(\.discoveryCardRemoval) private var remove
  private var archiveID: Int64? { video.aid ?? ArchiveNumber.av(video.bvid) }
  private var mid: Int64? { video.owner?.mid.flatMap { $0 > 0 ? $0 : nil } }

  @EnvironmentObject private var accounts: AccountContext
  func body(content: Content) -> some View {
    content.contextMenu {
      if ArchiveNumber.av(video.bvid) != nil {
        Button("复制 BV 号", systemImage: "doc.on.doc") { UIPasteboard.general.string = video.bvid }
      }
      if mid != nil {
        Button("访问 " + (video.owner?.name ?? "UP 主"), systemImage: "person.crop.circle") {
          previewCreator = true
        }
      }
      if summaryEnabled, let cid = video.cid, cid > 0, ArchiveNumber.av(video.bvid) != nil {
        Button("视频总结", systemImage: "text.quote") { previewSummary = true }
      }
      if let mid, accounts.state.active != String(mid) {
        Button("屏蔽 UP 主", systemImage: "person.slash") {
          requestOwner = accounts.state.active
          block = true
        }
      }
      if video.recommendGoto == nil, let uid = accounts.state.active, let aid = archiveID, aid > 0 {
        Menu("不感兴趣", systemImage: "hand.thumbsdown") {
          Button("点踩") { sendDislike(aid, uid, false) }
          Button("撤销点踩") { sendDislike(aid, uid, true) }
        }
      }
      if let cover = video.cover {
        Button("查看封面", systemImage: "photo") { preview = true }
        Button("保存封面", systemImage: "square.and.arrow.down") {
          run("封面已保存") { _ = try await GalleryAssets().savePictures([.init(cover)]) }
        }
        Button("复制封面地址", systemImage: "doc.on.doc") { UIPasteboard.general.url = cover }
      }
      if let uid = accounts.state.active, let aid = video.aid ?? ArchiveNumber.av(video.bvid) {
        Button("添加到稍后再看", systemImage: "clock") {
          run("已加入稍后再看") {
            try await BiliAPI.shared.submit(
              "/x/v2/history/toview/add", ["aid": String(aid)], expectedAccount: uid)
          }
        }
      }
      extra
    }
    .piliSheet(isPresented: $preview) {
      if let url = video.cover {
        PiliNavigationStack {
          NativeGallery([.init(url)]).toolbar { Button("完成") { preview = false } }
        }
      }
    }
    .piliSheet(isPresented: $previewCreator) {
      if let mid {
        PiliNavigationStack {
          CreatorSpace(mid: mid, name: video.owner?.name ?? "UP 主").toolbar {
            Button("完成") { previewCreator = false }
          }
        }
      }
    }
    .piliSheet(isPresented: $previewSummary) {
      if let cid = video.cid {
        PiliNavigationStack {
          CardVideoSummary(video: video, cid: cid).toolbar {
            Button("完成") { previewSummary = false }
          }
        }
      }
    }
    .confirmationDialog(
      "屏蔽 " + (video.owner?.name ?? "UP 主") + "？", isPresented: $block, titleVisibility: .visible
    ) {
      if let mid {
        Button("仅在本机屏蔽") { run("已在本机屏蔽") { try hideCreator(mid) } }
        if let uid = requestOwner, uid == accounts.state.active {
          Button("加入账号黑名单", role: .destructive) {
            run("已加入黑名单") {
              try await BiliAPI.shared.submit(
                "/x/relation/modify", ["fid": String(mid), "act": "5", "re_src": "11"],
                expectedAccount: uid)
              if accounts.state.active == uid { remove?(.init(archive: video.bvid, creator: mid)) }
            }
          }
        }
      }
    }
    .alert("已点踩", isPresented: $dislikeUndo) {
      Button("撤销") {
        if let uid = requestOwner, uid == accounts.state.active, let aid = archiveID {
          sendDislike(aid, uid, true)
        }
      }
      Button("完成") {
        if requestOwner == accounts.state.active {
          remove?(.init(archive: video.bvid, creator: nil))
        }
      }
    }
    .alert("视频", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
      Button("好") {}
    } message: {
      Text(result ?? "")
    }
  }
  private func hideCreator(_ mid: Int64) throws {
    var rules = RecommendationRules.current()
    rules.blockedCreators.insert(mid)
    try rules.save()
    remove?(.init(archive: video.bvid, creator: mid))
  }
  private func sendDislike(_ aid: Int64, _ owner: String, _ undo: Bool) {
    guard !saving, accounts.state.active == owner else { return }
    saving = true
    requestOwner = owner
    Task { @MainActor in
      defer { saving = false }
      do {
        try await BiliAPI.shared.archiveDislike(aid, undo: undo, owner: owner)
        guard accounts.state.active == owner else { return }
        if undo { result = "已撤销点踩" } else { dislikeUndo = true }
      } catch { if accounts.state.active == owner { result = error.localizedDescription } }
    }
  }
  private func run(_ text: String, _ work: @escaping @MainActor () async throws -> Void) {
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
}
extension View {
  func archiveCover<Extra: View>(_ video: Video, @ViewBuilder extra: () -> Extra) -> some View {
    modifier(ArchiveCoverMenu(video: video, extra: extra()))
  }
  func archiveCover(_ video: Video) -> some View { archiveCover(video) { EmptyView() } }
}
