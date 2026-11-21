import PiliWire
import SwiftUI

struct ListenMetadata: View {
  let track: ListenTrack
  @ObservedObject var queue: ListenQueue
  @ObservedObject var catalog: ListenerCatalog
  /// The page's transport, shown between the title block and the actions.
  var transport: AnyView? = nil
  @State private var expanded = false
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.openURL) private var openURL
  @AppStorage("detail.coinLike") private var coinLike = false
  @AppStorage("detail.quickFav") private var quick = false
  @AppStorage("detail.quickFolder") private var preferred = ""
  @State private var sharing: MediaMomentSelection?
  @State private var showCoins = false
  @State private var showTriple = false
  @State private var showFolders = false
  @State private var clearFav = false
  @State private var busy = false
  @State private var issue: String?
  @State private var song: AudioSong?
  private var record: ListenerGateway.Row? { catalog.records[track.bvid] }
  private var title: String { record?.arc.title ?? track.archiveTitle ?? track.title }
  private var reference: URL? {
    if let s = track.songID { return URL(string: "https://www.bilibili.com/audio/au\(s)") }
    return URL(string: "https://www.bilibili.com/video/" + track.bvid)
  }
  private var ridType: Int { track.songID == nil ? 2 : 12 }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let url = httpsURL(record?.arc.cover ?? track.cover) {
        GalleryLink([.init(url)], index: 0) {
          Rectangle().fill(.quaternary).aspectRatio(16 / 10, contentMode: .fit)
            .overlay { SiteThumbnail(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear } }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        }.buttonStyle(.plain)
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.title3.weight(.bold)).lineLimit(2).textSelection(.enabled)
        HStack(spacing: 8) {
          if let mid = (record?.owner.mid ?? track.ownerID), mid > 0 {
            LazyLink {
              CreatorSpace(mid: mid, name: track.artist).onAppear { queue.pause() }
            } label: {
              HStack(spacing: 4) {
                Text(track.artist.isEmpty ? "UP 主" : track.artist)
                Image(systemName: "chevron.right").font(.caption2.weight(.bold))
              }.font(.subheadline).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
          } else if !track.artist.isEmpty {
            Text(track.artist).font(.subheadline).foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
          if let r = record {
            Text(MediaStats.line(views: Int(r.stat.view), extra: [r.arc.publish > 0 ? MediaStats.published(Int64(r.arc.publish)) : nil]))
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      if let transport { transport }
      if let oid = track.objectID { actions(oid) }
      if let desc = record.flatMap({ $0.arc.desc.isEmpty ? nil : $0.arc.desc }) ?? song?.intro,
        !desc.isEmpty
      {
        Text(desc).font(.subheadline).foregroundStyle(.secondary).lineLimit(expanded ? nil : 3)
          .textSelection(.enabled)
          .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
      }
      extras
      if let issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
    }.mediaMomentSheet($sharing)
      .task(id: track.songID) {
        song = nil
        if let s = track.songID {
          let loaded = try? await BiliAPI.shared.song(s)
          if !Task.isCancelled {
            song = loaded
            if let loaded { queue.hydrateSong(loaded) }
          }
        }
      }
      .piliSheet(
        isPresented: $showFolders,
        onDismiss: { if queue.current?.bvid == track.bvid { Task { await catalog.load(.first) } } }
      ) {
        if let uid = accounts.state.active, let oid = track.objectID {
          PiliNavigationStack {
            PickFolder(uid: uid, aid: oid, resourceType: ridType).toolbar {
              Button("取消") { showFolders = false }
            }
          }
        }
      }
      .confirmationDialog("为这条内容三连？", isPresented: $showTriple, titleVisibility: .visible) {
        Button("点赞、投币并收藏") { act(.triple) }
      }
      .confirmationDialog("选择投币数量", isPresented: $showCoins, titleVisibility: .visible) {
        Button("1 个硬币") { act(.coin(1, coinLike)) }
        if record?.arc.copyright != 2 { Button("2 个硬币") { act(.coin(2, coinLike)) } }
      }
      .confirmationDialog("从所有收藏夹移除？", isPresented: $clearFav, titleVisibility: .visible) {
        Button("移除", role: .destructive) { favorite(remove: true) }
        Button("手动选择收藏夹") { showFolders = true }
      }
  }
  /// The video page's own action column (KingActionItem): the official glyphs, sizes and tints.
  private func column(_ symbol: String, _ value: String, active: Bool = false, icon: BiliIcon? = nil) -> some View {
    ArchiveActionColumn(symbol: symbol, title: value, active: active, icon: icon)
  }
  private func short<N: BinaryInteger>(_ n: N) -> String {
    n > 0 ? Int64(n).formatted(.number.notation(.compactName)) : ""
  }
  /// The original client's action row: like, coin, favourite, comments and share.
  @ViewBuilder private func actions(_ oid: Int64) -> some View {
    let stat = record?.stat
    HStack(spacing: 0) {
      if accounts.state.active != nil {
        Button { act(.like(!(stat?.hasLike_p ?? false))) } label: {
          column("hand.thumbsup",
            stat.map { short($0.like) }.flatMap { $0.isEmpty ? nil : $0 } ?? "点赞", active: stat?.hasLike_p == true,
            icon: .likeFill)
        }
        .accessibilityLabel("点赞")
        .contextMenu { Button("三连", systemImage: "sparkles") { showTriple = true } }
        Button { showCoins = true } label: {
          column(ArchiveActionColumn.coin, stat.map { short($0.coin) }.flatMap { $0.isEmpty ? nil : $0 } ?? "投币",
            icon: .coinFill)
        }
        .accessibilityLabel("投币")
        Button {
          if quick { favorite(remove: false) } else { showFolders = true }
        } label: {
          column("star",
            stat.map { short($0.favourite) }.flatMap { $0.isEmpty ? nil : $0 } ?? "收藏", active: stat?.hasFav_p == true,
            icon: .starFill)
        }
        .accessibilityLabel("收藏")
        .contextMenu {
          Button("选择收藏夹", systemImage: "folder") { showFolders = true }
          Button("三连", systemImage: "sparkles") { showTriple = true }
        }
      }
      NavigationLink { DeferredPage { Discussion(oid: oid, type: track.songID == nil ? 1 : 14) } } label: {
        column("text.bubble", stat.map { short($0.reply) }.flatMap { $0.isEmpty ? nil : $0 } ?? "评论")
          .accessibilityLabel("评论")
      }
      if let u = reference {
        Menu {
          Button("复制链接", systemImage: "link") { UIPasteboard.general.url = u }
          Button("使用其他应用打开", systemImage: "arrow.up.forward.app") { openURL(u) }
          ShareLink(item: u, subject: Text(title), message: Text(title + " · " + track.artist))
          MediaMomentButton(resource: .listening(track), selection: $sharing)
          if track.songID == nil, let oid = track.objectID {
            IMShareButton(
              card: .init(
                .video, id: String(oid), title: title, author: track.artist,
                authorID: track.ownerID.map(String.init), thumb: httpsURL(track.cover)))
          }
        } label: {
          column("arrowshape.turn.up.right", stat.map { short($0.share) }.flatMap { $0.isEmpty ? nil : $0 } ?? "分享",
            icon: .shareFill)
        }
        .accessibilityLabel("分享")
      }
    }
    .environment(\.engagementFills, true)
    .buttonStyle(ActionPressStyle()).disabled(busy)
  }
  /// Lyrics, MV, report and the archive number as small glass capsules.
  @ViewBuilder private var extras: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        if let lyr = song?.lyric.flatMap(httpsURL) {
          NavigationLink { DeferredPage { SongLyric(url: lyr, songID: track.songID) } } label: { capsule("歌词", "quote.bubble") }
        }
        if let related = record?.associatedItem, related.oid > 0, let part = related.subID.first,
          part > 0, let bv = ArchiveNumber.bv(related.oid)
        {
          LazyLink {
            DetailView(
              initial: .preview(id: bv, title: title, cover: track.cover, author: track.artist),
              libraryPoint: .init(cid: part, seconds: 0)
            ).onAppear { queue.pause() }
          } label: { capsule("看 MV", "play.rectangle") }
        } else if let bv = song?.bvid, !bv.isEmpty {
          LazyLink {
            DetailView(initial: .preview(id: bv, title: title, cover: track.cover, author: track.artist))
              .onAppear { queue.pause() }
          } label: { capsule("看 MV", "play.rectangle") }
        }
        Button { UIPasteboard.general.string = track.bvid; issue = "已复制 " + track.bvid } label: {
          capsule(track.bvid, "doc.on.doc")
        }
        if let oid = track.objectID, let url = URL(string: "https://www.bilibili.com/appeal/?avid=" + String(oid)) {
          NavigationLink { DeferredPage { SitePage(url: url) } } label: { capsule("举报", "exclamationmark.bubble") }
        }
      }
    }
    .scrollClipDisabled().buttonStyle(.plain)
  }
  private func capsule(_ text: String, _ symbol: String) -> some View {
    Label(text, systemImage: symbol).font(.footnote.weight(.medium)).lineLimit(1)
      .padding(.horizontal, 12).padding(.vertical, 7)
      .piliGlass(in: Capsule(), interactive: true)
  }
  private func act(_ action: ListenerGateway.Action) {
    guard !busy, let uid = accounts.state.active else { return }
    busy = true
    Task { @MainActor in
      defer { busy = false }
      do {
        let text = try await catalog.update(action, track: track, owner: uid)
        guard accounts.state.active == uid else { return }
        issue = text
      } catch {
        if !Task.isCancelled && accounts.state.active == uid { issue = error.localizedDescription }
      }
    }
  }
  private func favorite(remove: Bool) {
    guard !busy, let uid = accounts.state.active, let oid = track.objectID else { return }
    busy = true
    Task { @MainActor in
      defer { busy = false }
      do {
        if remove {
          try await BiliAPI.shared.submit(
            "/x/v3/fav/resource/unfav-all", ["rid": String(oid), "type": String(ridType)],
            expectedAccount: uid)
        } else {
          let folders = try await BiliAPI.shared.folders(
            uid: uid, videoID: oid, resourceType: ridType, expectedAccount: uid)
          guard accounts.state.active == uid else { return }
          guard folders.allSatisfy({ $0.fav_state == 0 || $0.fav_state == 1 }) else {
            throw ServiceError("无法读取收藏状态")
          }
          if folders.contains(where: { $0.fav_state == 1 }) {
            clearFav = true
            return
          }
          guard let f = folders.first(where: { String($0.id) == preferred }) ?? folders.first else {
            showFolders = true
            return
          }
          try await BiliAPI.shared.submit(
            "/x/v3/fav/resource/batch-deal",
            ["resources": "\(oid):\(ridType)", "add_media_ids": String(f.id)], expectedAccount: uid)
        }
        if accounts.state.active == uid {
          await catalog.load(.first)
          issue = remove ? "已取消收藏" : "已收藏"
        }
      } catch { if accounts.state.active == uid { issue = error.localizedDescription } }
    }
  }
}
