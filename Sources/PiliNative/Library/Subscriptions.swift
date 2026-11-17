import SwiftUI

struct Subscription: Decodable, Identifiable {
  struct Owner: Decodable { let mid: Int64?, name: String? }
  struct Count: Decodable { let play: Int64? }
  let id: Int64
  var type: Int? = nil, title: String? = nil, intro: String? = nil, media_count: Int? = nil
  var cover: String? = nil, state: Int? = nil, upper: Owner? = nil, view_count: Int64? = nil,
    cnt_info: Count? = nil
  var kind: String { type == 11 ? "收藏夹" : type == 21 ? "合集" : "订阅" }
  var name: String { title ?? kind }
  var picture: URL? { cover.flatMap(GalleryPicture.source) }
  var count: Int64? { view_count ?? cnt_info?.play }
}
struct Subscriptions: View {
  let uid: String
  @State private var pending: Subscription?
  @State private var error: String?
  @State private var revision = 0
  @State private var busy = false
  @State private var cover: URL?
  @State private var creator: Int64?
  @State private var creatorName = ""
  struct Feed: Decodable { let list: [Subscription]?, has_more: Bool? }
  var body: some View {
    PageList(empty: "暂无订阅") { cursor in
      let p = Int(cursor ?? "1") ?? 1
      let r = try await BiliAPI.shared.read(
        "/x/v3/fav/folder/collected/list",
        ["up_mid": uid, "ps": "20", "pn": "\(p)", "platform": "web"], expectedAccount: uid,
        as: Feed.self)
      let rows = r.list ?? []
      return Page(items: rows, next: !rows.isEmpty && r.has_more == true ? "\(p+1)" : nil)
    } row: { s in
      Group {
        if s.state == 1 {
          label(s).foregroundStyle(.secondary)
        } else if s.type == 11 {
          PlainRowLink {
            FavoriteFolderScreen(id: s.id) { revision += 1 }
          } label: {
            label(s)
          }
        } else {
          PlainRowLink {
            SubscriptionCollection(item: s)
          } label: {
            label(s)
          }
        }
      }
      .contextMenu {
        if let picture = s.picture { Button("查看封面", systemImage: "photo") { cover = picture } }
        if let mid = s.upper?.mid {
          Button("查看创建者", systemImage: "person.crop.circle") {
            creatorName = s.upper?.name ?? "用户空间"
            creator = mid
          }
        }
        Button("取消订阅", systemImage: "minus.circle", role: .destructive) { pending = s }
      }.swipeActions { Button("取消订阅", role: .destructive) { pending = s } }
    }.id("\(uid):\(revision)").navigationTitle("我的订阅")
      .navigationDestination(item: $cover) { NativeGallery([.init($0)]) }
      .navigationDestination(item: $creator) { CreatorSpace(mid: $0, name: creatorName) }
      .confirmationDialog(
        "取消订阅？", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
        presenting: pending
      ) { s in
        Button("取消订阅", role: .destructive) { Task { await remove(s) } }
      }.alert("订阅", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
        Button("好") {}
      } message: {
        Text(error ?? "")
      }
  }
  private func label(_ s: Subscription) -> some View {
    MediaRow(
      cover: s.picture, title: s.name,
      badge: s.state == 1 ? "已失效" : s.kind,
      subtitle: s.upper?.name,
      detail: s.media_count.map { "\($0) 个内容" },
      dimmed: s.state == 1)
  }
  private func remove(_ s: Subscription) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      try await BiliAPI.shared.submit(
        s.type == 11 ? "/x/v3/fav/folder/unfav" : "/x/v3/fav/season/unfav",
        s.type == 11 ? ["media_id": String(s.id)] : ["platform": "web", "season_id": String(s.id)],
        expectedAccount: uid)
      revision += 1
    } catch { self.error = error.localizedDescription }
  }
}
struct SubscriptionCollection: View {
  let item: Subscription
  @EnvironmentObject private var accounts: AccountContext
  @State private var reverse: Bool
  @State private var metadata: Subscription?
  @State private var cover: URL?
  @State private var creator: Int64?
  init(item: Subscription) {
    self.item = item
    _reverse = State(initialValue: (item.media_count ?? 0) > 0)
  }
  private var info: Subscription { metadata ?? item }
  struct Result: Decodable {
    struct Media: Decodable {
      struct Counts: Decodable { let play: Int?, danmaku: Int? }
      let id: Int64?, bvid: String?, title: String?, cover: String?, duration: Int?
      var cnt_info: Counts? = nil, pubtime: Int64? = nil
    }
    let info: Subscription?, medias: [Media]?
  }
  var body: some View {
    let uid = accounts.state.active ?? ""
    PageList(empty: "暂无视频", heading: AnyView(header)) { cursor in
      let step = Int(cursor ?? "1") ?? 1
      let total = info.media_count ?? 0
      let requested = reverse ? max(1, (total + 19) / 20 - step + 1) : step
      let r = try await BiliAPI.shared.read(
        "/x/space/fav/season/list",
        ["season_id": String(item.id), "ps": "20", "pn": String(requested)], expectedAccount: uid,
        as: Result.self)
      try Task.checkCancellation()
      if cursor == nil, let fresh = r.info { metadata = fresh }
      let raw = r.medias ?? []
      let rows = raw.compactMap { m -> Video? in
        guard let bv = m.bvid ?? m.id.flatMap(ArchiveNumber.bv) else { return nil }
        var row = Video.preview(
          id: bv, title: m.title ?? bv, cover: m.cover ?? "", author: nil, duration: m.duration,
          views: m.cnt_info?.play, danmaku: m.cnt_info?.danmaku, published: m.pubtime)
        row.aid = m.id
        return row
      }
      let more =
        reverse
        ? requested > 1
        : (r.info?.media_count ?? info.media_count).map { requested * 20 < $0 } ?? (raw.count == 20)
      return Page(
        items: reverse ? Array(rows.reversed()) : rows,
        next: !raw.isEmpty && more ? String(step + 1) : nil)
    } row: {
      VideoLink(video: $0, hidesOwner: true)
    }
    .id("\(uid):\(reverse)").navigationTitle(info.name)
    .navigationDestination(item: $cover) { NativeGallery([.init($0)]) }
    .navigationDestination(item: $creator) {
      CreatorSpace(mid: $0, name: info.upper?.name ?? item.upper?.name ?? "用户空间")
    }
    .toolbar {
      if (info.media_count ?? 0) > 0 {
        Button {
          reverse.toggle()
        } label: {
          Label(reverse ? "改为正序" : "改为倒序", systemImage: "arrow.up.arrow.down")
        }
      }
    }
  }
  /// Same header as a favourite folder: cover, title, creator, counts, then the introduction.
  /// One row may hold only one navigation target, so the cover and creator push through state.
  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 14) {
        if let image = info.picture ?? item.picture {
          Button { cover = image } label: {
            SiteThumbnail(url: image) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
              .frame(width: 140, height: 88).background(.quaternary).clipped()
              .clipShape(RoundedRectangle(cornerRadius: NativeGlass.cardRadius, style: .continuous))
          }.buttonStyle(.plain).accessibilityLabel("查看封面")
        }
        VStack(alignment: .leading, spacing: 6) {
          Text(info.name).font(.headline).lineLimit(2)
          if let mid = info.upper?.mid ?? item.upper?.mid {
            Button { creator = mid } label: {
              HStack(spacing: 4) {
                Image(systemName: "person.crop.circle").font(.subheadline)
                Text(info.upper?.name ?? item.upper?.name ?? "创建者").font(.subheadline)
              }.foregroundStyle(.secondary)
            }.buttonStyle(.plain)
          }
          Spacer(minLength: 0)
          Text(
            [
              info.kind,
              info.media_count.map { "\($0) 个视频" },
              info.count.map { "\($0.formatted(.number.notation(.compactName))) 播放" },
            ].compactMap { $0 }.joined(separator: " · ")
          )
          .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(height: 88, alignment: .topLeading)
      }
      .fixedSize(horizontal: false, vertical: true)
      if let intro = info.intro, !intro.isEmpty {
        Text(intro).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 4)
    .listRowSeparator(.hidden)
  }
}
