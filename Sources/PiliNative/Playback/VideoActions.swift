import SwiftUI

struct VideoActions: View {
  let video: Video
  let cid: Int64
  @ObservedObject var model: PlayerModel
  let seconds: () -> Double
  @EnvironmentObject var accounts: AccountContext
  @Environment(\.listenOrigin) private var origin
  @ObservedObject private var laterBook=PlayerKeyMemory.shared
  private var laterMarked:Bool{
    guard let uid=accounts.state.active,let id=video.aid ?? ArchiveNumber.av(video.bvid) else{return false}
    return laterBook.contains(id,owner:uid,origin:origin?.source==8 && origin?.extra==2 && origin?.id==Int64(uid))
  }
  @AppStorage("detail.related") private var showRelated = true
  @AppStorage("detail.replies") private var showReplies = true
  @State private var busy = false
  @State private var notice: String?
  @State private var sharingMoment: MediaMomentSelection?
  @State private var writeBullet = false
  @State private var message = ""
  let onBullet: (Bullet) -> Void
  var openComments: (() -> Void)? = nil
  var showsEngagement = true
  @State private var at = 0.0
  var body: some View {
    // The column that ends the engagement row, as in the original's five (赞 · 不喜欢 · 投币 ·
    // 收藏 · 分享): share, with cache, watch later and the rarely used tools in its menu.
    // The column is drawn outside the menu, which is an invisible layer over it: iOS 26 folds a
    // menu label's glass into one larger glass around the whole column (glyph and count).
    ArchiveActionColumn(symbol: "arrowshape.turn.up.right",
      title: (video.stat?.share ?? 0) > 0 ? (video.stat?.share ?? 0).formatted(.number.notation(.compactName)) : "分享",
      active: false, icon: .shareFill)
    .accessibilityHidden(true)
    .overlay { Menu {
      Section {
        NavigationLink { DeferredPage { CacheSelection(video: video, cid: cid) } } label: {
          Label("离线缓存", systemImage: "arrow.down.circle")
        }
        Button {
          guard let owner=accounts.state.active else{notice="请先登录";return}
          let removing=laterMarked
          let item=EngagementItem(bvid:video.bvid,aid:video.aid,episode:nil,copyright:video.copyright)
          TouchFeedback.light()
          act(removing ? "已移出稍后再看":"已加入稍后再看"){
            let request=try PlaybackSocialRequest.later(item,removing:removing)
            try await BiliAPI.shared.submit(request.path,request.fields,expectedAccount:owner)
            if owner==accounts.state.active,let aid=video.aid ?? ArchiveNumber.av(video.bvid){PlayerKeyMemory.shared.mark(aid,owner:owner,value:!removing)}
          }
        } label: {
          Label(laterMarked ? "移出稍后再看" : "稍后再看", systemImage: laterMarked ? "clock.fill" : "clock")
        }
      }
      let page=video.pages?.first(where:{$0.cid==cid})?.page
      if let url=ArchiveSharePoint.archive(video.bvid,page:page){
        Section {
          ArchiveShareButtons(normal:url){ArchiveSharePoint.archive(video.bvid,page:page,time:seconds())}
          MediaMomentButton(resource: .archive(video), selection: $sharingMoment)
          if let aid = video.aid, aid > 0 {
            IMShareButton(
              card: .init(
                .video, id: String(aid), title: video.title, author: video.owner?.name,
                authorID: video.owner?.mid.map(String.init), thumb: video.cover))
          }
          NavigationLink {
            SharePoster(
              content: .init(
                title: video.title, body: "", author: video.owner?.name ?? "", date: "",
                kind: "视频", link: url, cover: video.cover))
          } label: { Label("生成分享卡片", systemImage: "photo.on.rectangle") }
        }
      }
      Section {
        Button {
          at = seconds()
          writeBullet = true
        } label: { Label("发弹幕", systemImage: "text.bubble") }.disabled(accounts.state.active == nil)
        if let cover = video.cover {
          NavigationLink { DeferredPage { NativeGallery([.init(cover)]) } } label: { Label("查看封面", systemImage: "photo") }
          Button {
            act("封面已保存") { _ = try await GalleryAssets().savePictures([.init(cover)]) }
          } label: { Label("保存封面", systemImage: "square.and.arrow.down") }
        }
        ArchiveTrendToggle(timeline:model.timeline)
      }
      Section {
        ArchiveSourceTools(model:model)
        if accounts.state.active != nil, let aid = video.aid,
          let appeal = URL(string: "https://www.bilibili.com/appeal/?avid=" + String(aid))
        {
          NavigationLink { DeferredPage { SitePage(url: appeal) } } label: { Label("举报视频", systemImage: "exclamationmark.bubble") }
        }
      }
    } label: {
      Color.clear.contentShape(Rectangle())
    }
    .menuStyle(.button).buttonStyle(.plain)
    .accessibilityLabel("分享与更多") }
    .mediaMomentSheet($sharingMoment)
    .piliSheet(isPresented: $writeBullet) {
      if let uid = accounts.state.active {
        BulletComposer(
          cid: cid, bvid: video.bvid, time: at, uid: uid, posted: onBullet, draft: $message)
      }
    }.onChange(of: accounts.state.active) { _, _ in
      writeBullet = false
      message = ""
    }
    .alert("视频", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
      Button("好") {}
    } message: {
      Text(notice ?? "")
    }
  }
  private func act(_ success: String, request: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    let owner = accounts.state.active
    busy = true
    Task { @MainActor in
      defer { busy = false }
      do {
        try await request()
        if accounts.state.active == owner { notice = success }
      } catch { if accounts.state.active == owner { notice = error.localizedDescription } }
    }
  }
}
