import SwiftUI

struct CreatorLibrary: View {
  let mid: Int64
  @AppStorage("creator.shop") private var shop = false
  enum Archive: String, CaseIterable {
    case likes = "点赞的视频"
    case coins = "投币的视频"
    case articles = "专栏投稿"
    case albums = "音乐投稿"
  }
  var body: some View {
    List {
      Section("投稿") {
        link("视频投稿", "play.rectangle.fill", .blue) { CreatorArchiveBrowser(source: .uploads(mid), title: "视频投稿") }
        link("合集和视频列表", "rectangle.stack.fill", .indigo) { CreatorCollections(mid: mid) }
        link("图文投稿", "doc.richtext.fill", .orange) { CreatorOpus(mid: mid) }
        link(Archive.articles.rawValue, "doc.text.fill", .orange) { CreatorWorks(mid: mid, kind: .articles) }
        link(Archive.albums.rawValue, "music.note", .pink) { CreatorWorks(mid: mid, kind: .albums) }
        link("漫画", "book.fill", .teal) { CreatorComics(mid: mid) }
        link("课堂", "graduationcap.fill", .green) { CoursesView(mid: String(mid)) }
      }
      Section("动态与互动") {
        link("动态", "text.bubble.fill", .cyan) { CreatorDynamics(mid: mid) }
        link(Archive.likes.rawValue, "hand.thumbsup.fill", .pink) { CreatorWorks(mid: mid, kind: .likes) }
        link(Archive.coins.rawValue, "bitcoinsign.circle.fill", .yellow) { CreatorWorks(mid: mid, kind: .coins) }
        link("收藏夹与订阅", "star.fill", .yellow) { CreatorFavorites(mid: mid) }
        link("追番追剧", "film.fill", .purple) { FollowedSeasons(uid: String(mid)) }
      }
      Section("粉丝") {
        link("充电排行榜", "bolt.fill", .orange) { SupporterRanks(mid: mid) }
        link("大航海", "ferry.fill", .blue) { CreatorGuards(mid: mid) }
        if shop { link("UP 主的小店", "bag.fill", .red) { CreatorShop(mid: mid) } }
        link("搜索空间", "magnifyingglass", .gray) { CreatorSearch(mid: mid) }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("空间内容")
  }
  private func link<D: View>(_ title: String, _ symbol: String, _ color: Color,
    @ViewBuilder _ destination: @escaping () -> D) -> some View {
    NavigationLink(destination: destination) {
      SettingsRowLabel(title: title, symbol: symbol, color: color)
    }
  }
}
struct CreatorWorks: View {
  let mid: Int64, kind: CreatorLibrary.Archive
  struct Row: Identifiable {
    let id: String, title: String, route: SharedLink, page: Int, cover: String?, date: Date?, plays: Int?, comments: Int?
    let dateText: String?, duration: Int?, badge: String?
  }
  @EnvironmentObject private var accounts: AccountContext
  @State private var songCount:Int?
  @State private var firstAudio:Int64?
  @State private var playAll=false
  var body: some View {
    PageList(empty: "暂无公开内容", grid: kind == .likes || kind == .coins, autoMore: true, heading: songCount.flatMap { $0 > 0 ? $0 : nil }.map { AnyView(Text("共" + String($0) + (kind == .albums ? "首" : "项")).font(.subheadline).foregroundStyle(.secondary)) }) { cursor in
      let page = Int(cursor ?? "1") ?? 1
      var host = "app.bilibili.com"
      var query = ["pn": "\(page)", "ps": "20", "vmid": "\(mid)"]
      let path: String
      switch kind {
      case .likes: path = "/x/v2/space/likearc"
      case .coins: path = "/x/v2/space/coinarc"
      case .articles:
        path = "/x/v2/space/article"
        query["ps"] = "10"
        query["platform"] = "ios"
        query["mobi_app"] = "iphone"
      case .albums:
        path = "/audio/music-service/web/song/upper"
        host = "api.bilibili.com"
        query = ["uid": "\(mid)", "pn": "\(page)", "ps": "20", "order": "1","web_location":"333.1387"]
      }
      let viewer = accounts.state.active
      let bytes = try await BiliAPI.shared.fetch(path, query, host: host, expectedAccount: viewer ?? "")
      try Task.checkCancellation()
      guard viewer == accounts.state.active else { throw CancellationError() }
      typealias Map = [String: Any]
      guard let root = try JSONSerialization.jsonObject(with: bytes) as? Map else {
        throw URLError(.cannotParseResponse)
      }
      guard root["code"] as? Int == 0 else {
        throw ServiceError(root["message"] as? String ?? "无法读取空间内容")
      }
      let data = root["data"] as? Map ?? [:]
      let rows = (data[kind == .albums ? "data" : "item"] as? [Map]) ?? []
      let items = rows.compactMap { v -> Row? in
        let title = v["title"] as? String ?? ""
        let uri = v["uri"] as? String ?? ""
        let param = v["param"] as? String ?? ""
        let link: SharedLink?
        switch kind {
        case .albums: link = (v["id"] as? NSNumber).map { .song($0.int64Value) }
        case .coins, .likes:
          if v["is_pgc"] as? Bool == true { link = SharedLink.parse(uri) }
          else {
            let target = Int64(param).flatMap { $0 > 0 ? SharedLink.archive($0, 1) : nil }
              ?? (v["bvid"] as? String).flatMap(SharedLink.parse) ?? SharedLink.parse(uri)
            if let target, let cid = v["first_cid"] as? Int64, cid > 0 { link = .archivePart(target, cid) }
            else { link = target }
          }
        case .articles:
          link =
            SharedLink.parse(uri)
            ?? URL(string: uri).flatMap { u in
              u.host == "article" || u.host == "read"
                ? Int64(u.lastPathComponent).map(SharedLink.article) : nil
            }
        }
        guard let link else { return nil }
        let stats = (v["statistic"] ?? v["stats"]) as? Map
        let date=(v["ctime"] as? NSNumber).map{Date(timeIntervalSince1970:$0.doubleValue/(kind == .albums && stats != nil ? 1000 : 1))}
        return Row(id: "\(link)", title: title, route: link, page: page, cover: (v["cover"] as? String) ?? (v["origin_image_urls"] as? [String])?.first,
          date: date, plays: (stats?["play"] ?? stats?["view"] ?? v["play"]) as? Int, comments: (stats?["comment"] ?? stats?["reply"] ?? v["danmaku"]) as? Int,
          dateText: v["publish_time_text"] as? String, duration: v["duration"] as? Int, badge: v["is_cooperation"] as? Bool == true ? "合作" : v["is_steins"] as? Bool == true ? "互动" : nil)
      }
      if page==1,kind == .albums {try Task.checkCancellation();firstAudio=items.first.flatMap{if case .song(let s)=$0.route{return s};return nil}}
      let total = data[kind == .albums ? "totalSize" : "count"] as? Int
      if page==1 {songCount=total}
      let count = kind == .articles ? 10 : 20
      return Page(
        items: items,
        next: (!rows.isEmpty && (total.map { page * count < $0 } ?? (rows.count == count)))
          ? "\(page+1)" : nil)
    } row: { v in
      if case .song(let id)=v.route{
        PlainRowLink {AudioCardEntry(id:id,title:v.title,origin:.member(mid,page:v.page))} label:{
          HStack(spacing: 12){
            SiteThumbnail(url:v.cover.flatMap(httpsURL)){$0.resizable().scaledToFill()}placeholder:{Color.clear}
              .frame(width:58,height:58).background(.quaternary).clipped().clipShape(RoundedRectangle(cornerRadius: NativeGlass.thumbRadius, style: .continuous))
            VStack(alignment:.leading,spacing:3){Text(v.title).font(.subheadline.weight(.medium)).lineLimit(2)
              if let date=v.date{Text(date,style:.date).font(.caption).foregroundStyle(.secondary)}
              HStack{if let p=v.plays{Label(String(p),systemImage:"headphones")};if let c=v.comments{Label(String(c),systemImage:"text.bubble")}}.font(.caption).foregroundStyle(.secondary)
            }
          }
        }.seasonCover(v.cover ?? "")
      }
      else {
        let when = (v.dateText?.isEmpty == false ? v.dateText : nil)
          ?? v.date.flatMap { MediaStats.published(Int64($0.timeIntervalSince1970)) }
        let stats = MediaStats.line(views: v.plays, danmaku: kind == .articles ? nil : v.comments,
          extra: kind == .articles ? [v.comments.map { "\($0)评论" }, when] : [when])
        if kind == .articles {
          PlainRowLink { LinkDestination(item: v.route) } label: {
            HStack(alignment: .top, spacing: 12) {
              VStack(alignment: .leading, spacing: 4) {
                Text(v.title).font(.subheadline.weight(.medium)).lineLimit(3)
                Spacer(minLength: 0)
                Text(stats).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }.frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
              if let u = v.cover.flatMap(httpsURL) {
                Rectangle().fill(.quaternary).frame(width: 112, height: 72)
                  .overlay { SiteThumbnail(url: u) { $0.resizable().scaledToFill() } placeholder: { Color.clear } }
                  .clipShape(RoundedRectangle(cornerRadius: NativeGlass.thumbRadius, style: .continuous))
              }
            }.padding(.vertical, 4).contentShape(Rectangle())
          }.seasonCover(v.cover ?? "")
        } else {
          PlainRowLink { LinkDestination(item: v.route) } label: {
            VStack(alignment: .leading, spacing: 6) {
              Rectangle().fill(.quaternary).aspectRatio(16 / 10, contentMode: .fit)
                .overlay {
                  SiteThumbnail(url: v.cover.flatMap(httpsURL)) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                }
                .overlay(alignment: .topLeading) {
                  if let badge = v.badge {
                    Text(badge).font(.caption2.weight(.semibold)).foregroundStyle(.white)
                      .padding(.horizontal, 5).padding(.vertical, 1.5)
                      .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                      .padding(6)
                  }
                }
                .overlay(alignment: .bottomTrailing) {
                  if let d = v.duration, d > 0 {
                    Text(clockText(Double(d))).font(.caption2.monospacedDigit().weight(.semibold))
                      .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2)
                      .background(.black.opacity(0.5), in: Capsule()).padding(6)
                  }
                }
                .clipShape(RoundedRectangle(cornerRadius: NativeGlass.cardRadius, style: .continuous))
              Text(v.title).font(.subheadline.weight(.medium)).lineLimit(2)
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
              Text(stats).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.contentShape(Rectangle())
          }.buttonStyle(.plain).seasonCover(v.cover ?? "")
        }
      }
    }.navigationTitle(kind.rawValue).toolbar{if kind == .albums && firstAudio != nil{Button("播放全部",systemImage:"play.fill"){playAll=true}}}
    .navigationDestination(isPresented:$playAll){if let id=firstAudio{AudioCardEntry(id:id,title:"",origin:.member(mid))}}
  }
}
struct CreatorCollections: View {
  let mid: Int64
  struct Meta: Decodable, Identifiable {
    let name: String?, series_id: Int64?, season_id: Int64?, total: Int?
    var cover: String? = nil, description: String? = nil
    var id: String { series_id.map { "series:\($0)" } ?? "season:\(season_id ?? 0)" }
  }
  struct Payload: Decodable {
    struct Lists: Decodable {
        struct Group: Decodable {
          struct Arc: Decodable { let pic: String? }
          let meta: Meta?, archives: [Arc]?
          /// Seasons often carry no cover of their own; the original client shows the first video's.
          var resolved: Meta? {
            guard var m = meta else { return nil }
            if (m.cover ?? "").isEmpty { m.cover = archives?.first?.pic }
            return m
          }
        }
      struct Count: Decodable { let total: Int? }
      let seasons_list: [Group]?, series_list: [Group]?, page: Count?
    }
    let items_lists: Lists?
  }
  var body: some View {
    PageList(empty: "暂无合集") { c in
      let p = Int(c ?? "1") ?? 1
      let data = try await BiliAPI.shared.read(
        "/x/polymer/web-space/seasons_series_list",
        ["mid": "\(mid)", "page_num": "\(p)", "page_size": "10"], as: Payload.self
      ).items_lists
      return Page(
        items: ((data?.seasons_list ?? []) + (data?.series_list ?? [])).compactMap(\.resolved),
        next: p * 10 < (data?.page?.total ?? 0) ? "\(p+1)" : nil)
    } row: { m in
      let label = MediaRow(
        cover: m.cover.flatMap(httpsURL), title: m.name ?? (m.season_id != nil ? "合集" : "视频列表"),
        badge: m.season_id != nil ? "合集" : "列表",
        subtitle: m.description.flatMap { $0.isEmpty ? nil : $0 },
        detail: m.total.map { "共 \($0) 个视频" }, thumbWidth: 128)
      if let season = m.season_id {
        PlainRowLink {
          CreatorArchiveBrowser(source: .season(mid, season), title: m.name ?? "合集")
        } label: { label }
      } else if let series = m.series_id {
        PlainRowLink {
          CreatorArchiveBrowser(source: .series(mid, series), title: m.name ?? "视频列表")
        } label: { label }
      }
    }.navigationTitle("合集和视频列表")
  }
}
