import SwiftUI

struct MusicDetailView: View {
  let id: String
  @State private var data: MusicRecord?
  @State private var issue: String?
  @State private var rev = 0
  @State private var busy = false
  @AppStorage("social.actionBar") private var actions = true
  @EnvironmentObject private var accounts: AccountContext
  private var owner: String { accounts.state.active ?? "" }
  var body: some View {
    let account = owner
    Group {
      if let m = data {
        let oid = m.music_comment?.oid ?? 0
        ReadingSplit(hasPanel:oid > 0) { summary(m) } panel: { header in
          Discussion(oid:oid,type:m.music_comment?.page_type ?? 47,embeddedTitle:"音乐详情",readingHeader:header)
        }
      } else if let issue {
        ContentUnavailableView { Label("音乐未能加载",systemImage:"music.note") } description:{ Text(issue) }
          actions:{ Button("重试"){ rev += 1 } }
      } else { PageLoading() }
    }.navigationTitle("音乐详情").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if data != nil {
          Menu { if let url = MusicRecord.link(id:id) { ShareLink(item:url) }; Button("刷新"){rev += 1} }
            label:{Label("更多",systemImage:"ellipsis.circle")}
        }
      }.task(id:"\(id):\(account):\(rev)") {
        data = nil; issue = nil
        do {
          let q = try await BiliAPI.shared.sign(["music_id":id,"relation_from":"bgm_page"])
          let v = try await BiliAPI.shared.read("/x/copyright-music-publicity/bgm/detail",q,expectedAccount:account,as:MusicRecord.self)
          try Task.checkCancellation(); guard owner == account else { return }; data = v
        } catch { if !Task.isCancelled, owner == account { issue = error.localizedDescription } }
      }
  }
  @ViewBuilder private func summary(_ m: MusicRecord) -> some View {
    VStack(alignment:.leading,spacing:12) {
      if let cover = m.mv_cover.flatMap(GalleryPicture.source) {
        let photo = GalleryPicture(cover)
        GalleryLink([photo],index:0) { GalleryThumb(photo:photo).frame(maxWidth:.infinity,maxHeight:190) }
      }
      let title = m.music_title ?? "音乐"
      Button { UIPasteboard.general.string = title } label: { Text(title).piliFont(.title,weight:.bold) }
        .buttonStyle(.plain).contextMenu { Button("复制歌名"){UIPasteboard.general.string = title} }
      ForEach(Array((m.artists_list ?? []).enumerated()),id:\.offset) { _, a in
        if let name = a.name, !name.isEmpty {
          if let mid = a.mid, mid > 0 {
            LazyLink { CreatorSpace(mid:mid,name:name) } label:{ artist(a,name) }
          } else { Button { UIPasteboard.general.string = name } label:{ artist(a,name) }.buttonStyle(.plain) }
        }
      }
      field("原唱",m.origin_artist ?? m.origin_artist_list); field("专辑",m.album); field("出处",m.music_source); field("发行日期",m.music_publish)
      if !m.awards.isEmpty { Text(m.awards.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary) }
      if let mv = m.mv { LazyLink { LinkDestination(item:mv) } label:{ Label("播放 MV",systemImage:"play.rectangle") } }
      if let heat = m.hot_song_heat?.last_heat { LabeledContent("热度",value:heat.formatted()) }
      if let pv = m.listen_pv { LabeledContent("总播放量",value:pv.formatted()) }
      NavigationLink { DeferredPage { MusicUses(id:id,title:title) } } label:{
        LabeledContent("使用这首音乐的投稿",value:m.music_relation?.formatted() ?? "")
      }
      if !m.trend.isEmpty { Text("近\(m.trend.count)日热度趋势").piliFont(.headline);SongHeatGraph(points:m.trend) }
      if actions {
        HStack {
          if let url = MusicRecord.link(id:id) { ShareLink(item:url) }
          Spacer()
          if owner.isEmpty { NavigationLink("登录后想听") { DeferredPage { QRLoginView() } } }
          else {
            Button { let account = owner; Task { await wish(m,account) } } label:{
              Label(m.wish_listen == true ? "已想听":"想听",systemImage:m.wish_listen == true ? "heart.fill":"heart")
            }.disabled(busy)
          }
          if let count = m.wish_count { Text(count.formatted()).font(.caption) }
        }
      }
      if let issue { Text(issue).foregroundStyle(.secondary) }
    }.padding(.vertical)
  }
  @ViewBuilder private func field(_ key:String,_ value:String?) -> some View {
    if let value, !value.isEmpty { LabeledContent(key,value:value).textSelection(.enabled) }
  }
  private func artist(_ a:MusicRecord.Artist,_ name:String) -> some View {
    HStack {
      if let avatar = a.face.flatMap(GalleryPicture.source) {
        SiteThumbnail(url:avatar) { $0.resizable().scaledToFill() } placeholder:{ Color.clear }
          .frame(width:26,height:26).clipShape(Circle())
      }
      Text(name); if let identity = a.identity,!identity.isEmpty { Text(identity).font(.caption).foregroundStyle(.secondary) }
    }
  }
  @MainActor private func wish(_ m:MusicRecord,_ account:String) async {
    guard !busy, !account.isEmpty, owner == account else { return }
    busy = true; defer {busy = false}
    do {
      try await BiliAPI.shared.submit("/x/copyright-music-publicity/bgm/wish/update",m.wishFields(id:id),expectedAccount:account)
      if owner == account { rev += 1 }
    } catch { if owner == account { issue = error.localizedDescription } }
  }
}

private struct MusicUses: View {
  let id:String, title:String
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    let owner = accounts.state.owner(.role(.recommend)) ?? ""
    PageList(empty:"暂无关联视频") { _ in
      let page = try await BiliAPI.shared.read("/x/copyright-music-publicity/bgm/recommend_list",["music_id":id],expectedAccount:owner,as:MusicClips.self)
      return Page(items:page.videos,next:nil)
    } row:{ c in
      if let route = c.route {
        let v = Video.preview(id:c.bvid ?? "",title:c.title ?? "",cover:c.cover ?? "",author:c.up_nick_name,duration:c.duration)
        LazyLink { LinkDestination(item:route) } label:{
          HStack {
            SiteThumbnail(url:v.cover){$0.resizable().scaledToFill()} placeholder:{Color.secondary.opacity(0.2)}
              .frame(width:104,height:62).clipped().cornerRadius(7)
            VStack(alignment:.leading,spacing:3){
              Text(c.title ?? "视频").lineLimit(2)
              if let name = c.up_nick_name {Text(name).font(.caption)}
              let tags = (c.label_list ?? []).compactMap(\.name).filter{ !$0.isEmpty }
              if !tags.isEmpty {Text(tags.joined(separator:" · ")).font(.caption2)}
              let stats = [c.duration.map{clockText(Double($0))},c.play.map{"\($0.formatted()) 播放"},c.danmu.map{"\($0.formatted()) 弹幕"}].compactMap{$0}
              if !stats.isEmpty {Text(stats.joined(separator:" · ")).font(.caption2).foregroundStyle(.secondary)}
            }
          }
        }.archiveCover(v)
      }
    }.id("\(id):\(owner)").navigationTitle(title)
  }
}
