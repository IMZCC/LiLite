import SwiftUI

struct CreatorSectionPreference: View {
  @AppStorage(CreatorSection.preference) private var choice = 0
  var body: some View {
    Picker("空间默认栏目", selection: $choice) {
      ForEach(CreatorSection.allCases) { Text($0.label).tag($0.rawValue) }
    }
  }
}

/// The original client's space home: per group a header with its count and "查看更多", then
/// video cards two to a row, posters three to a row, or compact rows for the rest.
struct CreatorHomePanel: View {
  let data: CreatorSpaceRecord, mid: Int64, owner: Bool
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 26) {
        if let room = data.room { liveCard(room) }
        ForEach(data.groups) { group in
          VStack(alignment: .leading, spacing: 12) {
            header(group)
            switch group.kind {
            case .archive, .coins, .likes:
              grid(columns: 2) {
                ForEach(group.items.prefix(group.kind == .archive ? 4 : 2)) {
                  CreatorMediaCard(row: $0, portrait: false)
                }
              }
            case .season, .comic:
              grid(columns: 3) {
                ForEach(group.items.prefix(3)) { CreatorMediaCard(row: $0, portrait: true) }
              }
            default:
              VStack(spacing: 4) {
                ForEach(group.items.prefix(2)) { CreatorMediaLink(row: $0) }
              }
            }
          }
        }
        if data.groups.isEmpty && data.room == nil {
          ContentUnavailableView("主页暂无内容", systemImage: "square.grid.2x2")
        }
      }
      .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 24)
    }
    .reportsScrollCollapse()
    .buttonStyle(.plain)
  }
  private func grid<C: View>(columns: Int, @ViewBuilder _ content: () -> C) -> some View {
    LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columns),
      alignment: .leading, spacing: 16, content: content)
  }
  private func header(_ group: CreatorSpaceRecord.Group) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(group.kind.label).font(.headline)
      Text("\(group.count)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
      if owner, let visible = group.visible {
        Image(systemName: visible ? "eye" : "eye.slash").font(.caption).foregroundStyle(.secondary)
          .accessibilityLabel(visible ? "公开" : "私密")
      }
      Spacer()
      NavigationLink {
        switch group.kind {
        case .archive: CreatorArchiveBrowser(source: .uploads(mid), title: "视频投稿")
        case .favorite: CreatorFavorites(mid: mid)
        case .coins: CreatorWorks(mid: mid, kind: .coins)
        case .likes: CreatorWorks(mid: mid, kind: .likes)
        case .article: CreatorOpus(mid: mid)
        case .audios: CreatorWorks(mid: mid, kind: .albums)
        case .comic: CreatorComics(mid: mid)
        case .season: CreatorMobileMedia(mid: mid, kind: .season, initial: group)
        }
      } label: {
        HStack(spacing: 2) {
          Text("查看更多")
          Image(systemName: "chevron.right").font(.caption2.weight(.bold))
        }.font(.subheadline).foregroundStyle(.secondary).contentShape(Rectangle())
      }
    }
  }
  private func liveCard(_ room: Int64) -> some View {
    LazyLink {
      LivePlayer(id: room, title: data.roomTitle ?? "直播间")
    } label: {
      HStack(spacing: 12) {
        Image(systemName: "dot.radiowaves.left.and.right").font(.body.weight(.semibold))
          .foregroundStyle(data.onAir ? Color.white : Color.accentColor)
          .frame(width: 40, height: 40)
          .background(data.onAir ? Color.pink : Color.accentColor.opacity(0.12), in: Circle())
          .symbolEffect(.variableColor.iterative, options: .repeating, isActive: data.onAir)
        VStack(alignment: .leading, spacing: 2) {
          Text(data.onAir ? "正在直播" : "直播间").font(.subheadline.weight(.semibold))
          if let t = data.roomTitle, !t.isEmpty {
            Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
      }
      .padding(12)
      .background(Color(uiColor: .secondarySystemGroupedBackground),
        in: RoundedRectangle(cornerRadius: NativeGlass.cardRadius, style: .continuous))
      .contentShape(Rectangle())
    }
  }
}

/// Grid card for space media: cover (16:9, or 3:4 for posters), two-line title, quiet note.
struct CreatorMediaCard: View {
  let row: CreatorSpaceRecord.Media
  let portrait: Bool
  var body: some View {
    NavigationLink {
      CreatorMediaDestination(row: row)
    } label: {
      VStack(alignment: .leading, spacing: 6) {
        Rectangle().fill(.quaternary).aspectRatio(portrait ? 3 / 4 : 16 / 10, contentMode: .fit)
          .overlay {
            SiteThumbnail(url: row.cover.flatMap(httpsURL)) { $0.resizable().scaledToFill() } placeholder: {
              Color.clear
            }
          }
          .overlay(alignment: .bottomTrailing) {
            if !portrait, let note = row.note, !note.isEmpty, note.contains(":") {
              Text(note).font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.5), in: Capsule()).padding(6)
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: NativeGlass.cardRadius, style: .continuous))
        Text(row.title).font(.subheadline.weight(.medium)).lineLimit(2)
          .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        if let note = row.note, !note.isEmpty, portrait || !note.contains(":") {
          Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

struct CreatorMediaDestination: View {
  let row: CreatorSpaceRecord.Media
  var body: some View {
    switch row.destination {
    case .link(let route): LinkDestination(item: route)
    case .folder(let id): CreatorFolderContents(id: id, title: row.title, collection: false)
    case .comic(let id):
      if let url = URL(string: "https://manga.bilibili.com/detail/mc\(id)") { SitePage(url: url) }
    }
  }
}

struct CreatorMediaLink: View {
  let row: CreatorSpaceRecord.Media
  @State private var cover = false
  var body: some View {
    PlainRowLink {
      CreatorMediaDestination(row: row)
    } label: {
      MediaRow(cover: row.cover.flatMap(httpsURL), title: row.title, subtitle: row.note)
    }.contextMenu {
      if row.cover.flatMap(httpsURL) != nil { Button("查看封面") { cover = true } }
    }.piliSheet(isPresented: $cover) {
      if let url = row.cover.flatMap(httpsURL) {
        PiliNavigationStack {
          NativeGallery([.init(url)], index: 0).toolbar { Button("完成") { cover = false } }
        }
      }
    }
  }
}

struct CreatorContributions: View {
  let mid: Int64, categories: [CreatorSpaceRecord.Tab]
  @State private var selection: String?
  private var current: CreatorSpaceRecord.Tab? {
    categories.first { $0.id == selection } ?? categories.first
  }
  private func title(_ t: CreatorSpaceRecord.Tab) -> String {
    t.title ?? [
      "video": "视频", "charging_video": "充电专属", "article": "专栏", "opus": "图文", "audio": "音乐",
      "comic": "漫画", "series": "列表", "season_video": "合集", "ugcSeason": "全部合集/列表",
    ][t.param] ?? "投稿"
  }
  var body: some View {
    VStack(spacing: 0) {
      if categories.count > 1, let current {
        ChipBar(
          items: categories.map(\.id),
          selection: Binding(get: { current.id }, set: { selection = $0 }),
          title: { id in categories.first { $0.id == id }.map(title) ?? "投稿" }
        ).padding(.vertical, 6)
      }
      if let tab = current {
        Group {
          switch tab.param {
          case "video": CreatorArchiveBrowser(source: .uploads(mid), title: title(tab), searchable: false)
          case "charging_video": CreatorMobileMedia(mid: mid, kind: .charging)
          case "article": CreatorWorks(mid: mid, kind: .articles)
          case "opus": CreatorOpus(mid: mid)
          case "audio": CreatorWorks(mid: mid, kind: .albums)
          case "comic": CreatorComics(mid: mid)
          case "series":
            if let n = tab.series {
              CreatorArchiveBrowser(source: .series(mid, n), title: title(tab))
            }
          case "season_video":
            if let n = tab.season {
              CreatorArchiveBrowser(source: .season(mid, n), title: title(tab))
            }
          case "ugcSeason": CreatorCollections(mid: mid)
          default: EmptyView()
          }
        }.id(tab.id).transition(.opacity)
      } else {
        CreatorArchiveBrowser(source: .uploads(mid), title: "投稿", searchable: false)
      }
    }
  }
}

struct CreatorMobileMedia: View {
  enum Kind { case charging, season }
  let mid: Int64, kind: Kind
  var initial: CreatorSpaceRecord.Group? = nil
  @State private var asc = false
  private struct Payload: Decodable {
    let item: [CreatorSpaceRecord.Item]?, count: Int?, has_next: Bool?, next: Int?
  }
  var body: some View {
    VStack(spacing: 0) {
      if kind == .charging {
        HStack {
          Spacer()
          Button {
            withAnimation(.snappy) { asc.toggle() }
          } label: {
            Label(asc ? "正序" : "倒序", systemImage: "arrow.up.arrow.down").font(.subheadline)
          }.buttonStyle(.plain).foregroundStyle(.secondary)
        }.padding(.horizontal, 16).padding(.vertical, 6)
      }
      PageList(empty: kind == .charging ? "没有充电专属投稿" : "暂无追番") { cursor in
        if kind == .season, cursor == nil, let initial, !initial.items.isEmpty {
          return Page(items: initial.items, next: initial.items.count < initial.count ? "2:" : nil)
        }
        let bits = cursor?.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let page = bits?.first.flatMap { Int($0) } ?? 1
        var q = [
          "vmid": String(mid), "pn": String(page), "ps": "20", "qn": "32", "mobi_app": "iphone",
          "platform": "ios",
        ]
        if kind == .charging {
          q["sort"] = asc ? "asc" : "desc"
          if bits?.count == 2, let value = bits?.last, !value.isEmpty { q["next"] = String(value) }
        }
        let r = try await BiliAPI.shared.read(
          kind == .charging ? "/x/v2/space/archive/charging" : "/x/v2/space/bangumi", q,
          host: "app.bilibili.com", as: Payload.self)
        let raw = r.item ?? []
        let more = r.has_next ?? r.count.map { page * 20 < $0 } ?? (raw.count == 20)
        return Page(
          items: raw.compactMap { $0.row(kind == .charging ? .archive : .season) },
          next: more && !raw.isEmpty ? "\(page+1):" + (r.next.map(String.init) ?? "") : nil)
      } row: { row in
        CreatorMediaLink(row: row)
      }.id(asc)
    }
  }
}

struct CreatorMedalWall: View {
  let mid: Int64
  struct Payload: Decodable {
    struct Row: Decodable {
      struct Badge: Decodable { let ruid: Int64?, name: String?, level: Int? }
      let target_name: String?, target_icon: String?, link: String?, live_status: Int?,
        uinfo_medal: Badge?
    }
    let list: [Row]?, count: Int?
  }
  @State private var count: Int?
  var body: some View {
    PageList(empty: "暂无粉丝勋章") { _ in
      let p = try await BiliAPI.shared.read(
        "/xlive/web-ucenter/user/MedalWall", ["target_id": String(mid)],
        host: "api.live.bilibili.com", as: Payload.self)
      try Task.checkCancellation()
      count = p.count
      return Page(
        items: (p.list ?? []).compactMap { row -> Medal? in
          guard let m = row.uinfo_medal, let uid = m.ruid, uid > 0 else { return nil }
          return Medal(id: uid, row: row)
        }, next: nil)
    } row: { medal in
      let r = medal.row
      PlainRowLink {
        if r.live_status == 1, let route = r.link.flatMap(SharedLink.parse), case .room = route {
          LinkDestination(item: route)
        } else {
          CreatorSpace(mid: medal.id, name: r.target_name ?? "用户空间")
        }
      } label: {
        HStack {
          SiteThumbnail(url: r.target_icon.flatMap(httpsURL)) {
            $0.resizable().scaledToFill()
          } placeholder: {
            Color.clear
          }
          .frame(width: 36, height: 36).clipShape(Circle())
          VStack(alignment: .leading) {
            Text(r.target_name ?? String(medal.id))
            Text(
              [r.uinfo_medal?.name, r.uinfo_medal?.level.map { "Lv.\($0)" }].compactMap { $0 }
                .joined(separator: " · ")
            ).font(.caption)
          }
          if r.live_status == 1 {
            Image(systemName: "dot.radiowaves.left.and.right").accessibilityLabel("直播中")
          }
        }
      }
    }.navigationTitle(count.map { "粉丝勋章墙（\($0)）" } ?? "粉丝勋章墙")
  }
  struct Medal: Identifiable { let id: Int64, row: Payload.Row }
}

struct CreatorIdentityView: View {
  let person: CreatorSpaceRecord.Person, mid: Int64, medals: Bool, ownsMedal: Bool
  var header: CreatorSpaceRecord.HeaderDetails? = nil
  var body: some View {
    Form {
      Section {
        if let face = person.face.flatMap(httpsURL) {
          GalleryLink([.init(face)], index: 0) {
            HStack {
              SiteThumbnail(url: face) {
                $0.resizable().scaledToFill()
              } placeholder: {
                Color.clear
              }
              .frame(width: 60, height: 60).clipShape(Circle())
              Text(person.name ?? "用户")
            }
          }
        }
        if let name = person.name { Button("复制昵称") { UIPasteboard.general.string = name } }
        Button { UIPasteboard.general.string = String(mid) } label: { LabeledContent("UID", value: String(mid)) }.accessibilityHint("轻点拷贝 UID")
        if let l = person.level { LabeledContent("等级", value: "Lv.\(l)") }
        if let text = person.verifyText, (person.verifyType ?? -1) >= 0 {
          LabeledContent("认证", value: text)
        }
        if let text = person.sign { Text(text).textSelection(.enabled) }
        if let text = person.birthday, !["0000-00-00", "0"].contains(text) {
          LabeledContent("生日", value: text)
        }
        if let n = person.registered, n > 0 {
          LabeledContent("注册日期") {
            Text(Date(timeIntervalSince1970: Double(n)), format: .dateTime.year().month().day())
          }
        }
      }
      Section {
        if let header { CreatorHeaderDetails(value: header, mid: mid, name: person.name, medals: medals) }
        CreatorSpaceMetrics(mid: mid, fallback: person)
        if ownsMedal { CreatorMedalName(mid: mid).id(mid) }
        if medals { NavigationLink("粉丝勋章墙") { DeferredPage { CreatorMedalWall(mid: mid) } } }
      }
    }.navigationTitle("空间资料")
  }
}

struct CreatorReservations: View {
  @Binding var items: [CreatorSpaceRecord.Reservation]
  @EnvironmentObject private var accounts: AccountContext
  @State private var pending = Set<Int64>()
  @State private var issue: String?
  var body: some View {
    List {
      ForEach(items, id: \.id) { (item: CreatorSpaceRecord.Reservation) in
        Section {
          Text(item.name).font(.headline)
          if let summary = item.summary { Text(summary).font(.subheadline) }
          if let seconds = item.date, seconds > 0 {
            Text(
              Date(timeIntervalSince1970: Double(seconds)),
              format: .dateTime.year().month().day().hour().minute()
            ).font(.subheadline)
          }
          Text("\(item.count) 人预约").foregroundStyle(.secondary)
          if let id = item.dynamic, !id.isEmpty, id != "0" {
            NavigationLink("预约动态") { DeferredPage { DynamicDetail(id: id) } }.piliTapFeedback()
          }
          if let prize = item.prize {
            if let route = item.prizeURL.flatMap(SharedLink.parse) {
              NavigationLink(prize) { LinkDestination(item: route) }
            } else if let url = item.prizeURL.flatMap(httpsURL), url.user == nil,
              url.password == nil, let host = url.host?.lowercased(),
              host == "bilibili.com" || host.hasSuffix(".bilibili.com")
            {
              NavigationLink(prize) { SitePage(url: url) }
            } else {
              Text(prize)
            }
          }
          if let uid = accounts.state.active {
            Button(item.followed ? "取消预约" : "预约") { Task { await update(item, uid) } }
              .disabled(pending.contains(item.id))
          } else {
            NavigationLink("登录后预约") { DeferredPage { QRLoginView() } }
          }
        }
      }
    }.navigationTitle("预约")
      .alert("预约", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
        Button("好") {}
      } message: {
        Text(issue ?? "")
      }
  }
  @MainActor private func update(_ item: CreatorSpaceRecord.Reservation, _ uid: String) async {
    guard accounts.state.active == uid, pending.insert(item.id).inserted else { return }
    defer { pending.remove(item.id) }
    do {
      try await BiliAPI.shared.submit(
        item.followed ? "/x/space/reserve/cancel" : "/x/space/reserve", ["sid": String(item.id)],
        expectedAccount: uid)
      guard accounts.state.active == uid, let i = items.firstIndex(where: { $0.id == item.id }),
        items[i].followed == item.followed
      else { return }
      items[i].followed.toggle()
      if item.followed {
        items[i].count = max(0, item.count - 1)
      } else if item.count < Int64.max {
        items[i].count += 1
      }
    } catch { if accounts.state.active == uid { issue = error.localizedDescription } }
  }
}
