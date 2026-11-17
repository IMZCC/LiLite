import SwiftUI

struct NoticeSource: View {
  let title: String
  let source: String?
  var body: some View {
    if let source, let route = SharedLink.parse(source) {
      NavigationLink(title) { LinkDestination(item: route) }
    } else if let source, let url = httpsURL(source) {
      NavigationLink(title) { SitePage(url: url).ignoresSafeArea() }
    } else {
      Text(title)
    }
  }
}
struct LikeNoticeDetail: View {
  let notice: Notice, uid: String
  @State private var card: LikeNoticePage.Card?
  var body: some View {
    VStack(alignment: .leading) {
      if let card {
        NoticeSource(
          title: [card.business, card.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(
            separator: " · "), source: notice.source
        ).padding(.horizontal)
      }
      PageList(empty: "暂无点赞记录") { cursor in
        guard let id = notice.number else { throw ServiceError("点赞记录不存在") }
        let p = (cursor ?? "").split(separator: ":")
        let page = p.count == 3 ? Int(p[0]) ?? 1 : 1
        let last = p.count == 3 ? Int64(p[1]) ?? 0 : 0
        let offset = p.count == 3 ? Int(p[2]) ?? 0 : 0
        let result = try await BiliAPI.shared.likedBy(id, page: page, last: last, uid: uid)
        try Task.checkCancellation()
        if cursor == nil { card = result.card }
        let rows = result.items ?? []
        let seen = offset + rows.count
        let more = result.page?.is_end != true && (notice.likes <= 0 || seen < notice.likes)
        let next =
          more ? rows.last.flatMap { $0.id != last ? "\(page+1):\($0.id):\(seen)" : nil } : nil
        return Page(items: rows, next: next)
      } row: { item in
        PlainRowLink {
          CreatorSpace(mid: item.user.mid, name: item.user.nickname ?? "用户空间")
        } label: {
          SessionRowLabel(
            photo: item.user.avatar.flatMap(httpsURL),
            name: item.user.nickname ?? String(item.user.mid),
            summary: "赞了你的内容",
            date: item.like_time.map { Date(timeIntervalSince1970: $0) })
        }
      }
    }.navigationTitle("点赞详情")
  }
}
struct NoticeFeed: View {
  let kind: NoticeKind
  @EnvironmentObject private var accounts: AccountContext
  @State private var revision = 0
  @State private var pending: Action?
  @State private var issue: String?
  @State private var busy = false
  @State private var route: NoticeRoute?
  @State private var likeTargets: [String: Notice] = [:]
  struct Action { let number: Int64, uid: String, mute: Bool? }
  enum NoticeRoute: Hashable {
    case link(SharedLink), web(URL), space(Int64, String), likes(String)
  }
  var body: some View {
    Group {
      if let uid = accounts.state.active {
        GroupedNoticeList(kind: kind) {
          try await BiliAPI.shared.notices(kind, cursor: $0, uid: uid)
        } row: { n in
          Group {
            if kind == .system { systemRow(n) } else { interactionRow(n) }
          }
          .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
          .alignmentGuide(.listRowSeparatorLeading) { _ in kind == .system ? 0 : 52 }
          .swipeActions {
            if let id = n.number {
              Button("删除", role: .destructive) { pending = .init(number: id, uid: uid, mute: nil) }
              if let muted = n.muted, kind == .like {
                Button(muted ? "接收通知" : "不再通知") {
                  pending = .init(number: id, uid: uid, mute: !muted)
                }.tint(.orange)
              }
            }
          }
          .contextMenu {
            if !n.text.isEmpty {
              Button("复制内容", systemImage: "doc.on.doc") { UIPasteboard.general.string = n.text }
            }
            if n.authors.count > 1 {
              ForEach(n.authors) { a in
                if let mid = a.mid {
                  Button(a.nickname ?? "UID " + String(mid), systemImage: "person.crop.circle") {
                    route = .space(mid, a.nickname ?? "用户空间")
                  }
                }
              }
            }
            if let u = n.picture.flatMap(GalleryPicture.source) {
              GalleryLink([.init(u)], index: 0) { Label("查看图片", systemImage: "photo") }
            }
          }
        }.id("\(uid):\(revision)").disabled(busy)
          .navigationDestination(item: $route) { r in
            switch r {
            case .link(let l): LinkDestination(item: l)
            case .web(let u): SitePage(url: u).ignoresSafeArea()
            case .space(let mid, let name): CreatorSpace(mid: mid, name: name)
            case .likes(let key):
              if let n = likeTargets[key] { LikeNoticeDetail(notice: n, uid: uid) }
            }
          }
      } else {
        ContentUnavailableView("登录后可查看通知", systemImage: "person.crop.circle")
      }
    }.navigationTitle(kind.rawValue).onDisappear {
      NotificationCenter.default.post(name: .piliUnreadChanged, object: nil)
    }
    .confirmationDialog(
      prompt, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
      presenting: pending
    ) { a in
      if a.mute == nil {
        Button("删除", role: .destructive) { Task { await change(a) } }
      } else {
        Button("确认") { Task { await change(a) } }
      }
    }.alert("通知", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
      Button("好") {}
    } message: {
      Text(issue ?? "")
    }
  }
  // MARK: rows
  private func primaryRoute(_ n: Notice) -> NoticeRoute? {
    if kind == .like && n.likes > 1 { return .likes(n.key) }
    if let link = n.anchored { return .link(link) }
    if let s = n.source {
      if let l = SharedLink.parse(s) { return .link(l) }
      if let u = httpsURL(s) { return .web(u) }
    }
    return nil
  }
  private func open(_ n: Notice) {
    guard let r = primaryRoute(n) else { return }
    if case .likes(let key) = r { likeTargets[key] = n }
    TouchFeedback.light()
    route = r
  }
  private func verb(_ n: Notice) -> String {
    let what = (n.business?.isEmpty == false ? n.business! : "评论")
    switch kind {
    case .reply: return "回复了我的" + what
    case .at: return "在" + what + "中@了我"
    case .like:
      return n.likes > 1 || n.authors.count > 1 ? "等 \(max(n.likes, n.authors.count)) 人赞了我的" + what : "赞了我的" + what
    case .system: return ""
    }
  }
  private func stamp(_ n: Notice) -> String? {
    if let t = n.time { return SessionRowLabel.stamp(Date(timeIntervalSince1970: t)) }
    return n.dateText
  }
  private func avatars(_ n: Notice) -> some View {
    let faces = n.authors.prefix(kind == .like ? 2 : 1).map { $0.avatar }
    let list = faces.isEmpty ? [n.photo] : Array(faces)
    return ZStack(alignment: .topLeading) {
      ForEach(Array(list.enumerated().reversed()), id: \.offset) { i, face in
        ZStack {
          Circle().fill(.quaternary)
          if let u = face.flatMap(httpsURL) {
            SiteThumbnail(url: u) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
          }
        }
        .frame(width: list.count > 1 ? 30 : 40, height: list.count > 1 ? 30 : 40).clipShape(Circle())
        .overlay { if list.count > 1 { Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2) } }
        .offset(x: CGFloat(i) * 10, y: CGFloat(i) * 10)
      }
    }
    .frame(width: 40, height: 40, alignment: .topLeading)
    .contentShape(Circle())
    .onTapGesture {
      if let a = n.authors.first, let mid = a.mid {
        route = .space(mid, a.nickname ?? n.title)
      }
    }
    .accessibilityHidden(true)
  }
  private func quote(_ q: String) -> some View {
    Text(q).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
      .padding(.leading, 8)
      .overlay(alignment: .leading) { Capsule().fill(.quaternary).frame(width: 3) }
  }
  @ViewBuilder private func trailingThumb(_ n: Notice) -> some View {
    if let u = n.picture.flatMap(GalleryPicture.source) {
      SiteThumbnail(url: u) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
        .frame(width: 56, height: 56).background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: NativeGlass.thumbRadius, style: .continuous))
    }
  }
  private func interactionRow(_ n: Notice) -> some View {
    let name = n.authors.first?.nickname ?? n.title
    return HStack(alignment: .top, spacing: 12) {
      avatars(n)
      VStack(alignment: .leading, spacing: 6) {
        Text("\(Text(name).fontWeight(.medium).foregroundStyle(.primary)) \(Text(verb(n)).foregroundStyle(.secondary))")
          .font(.subheadline).lineLimit(2)
        if kind == .like {
          if !n.text.isEmpty { quote(n.text) }
        } else {
          if !n.text.isEmpty {
            Text(n.text).font(.subheadline).lineSpacing(3).lineLimit(8)
          }
          ForEach(Array(n.quotes.prefix(1).enumerated()), id: \.offset) { _, q in quote(q) }
        }
        HStack(spacing: 10) {
          if let t = stamp(n) { Text(t).monospacedDigit() }
          if n.muted == true {
            Label("已关闭通知", systemImage: "bell.slash").labelStyle(.iconOnly)
          }
          if kind == .like, n.likes > 1 {
            Text("查看全部").foregroundStyle(.tint)
          }
        }
        .font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      trailingThumb(n)
    }
    .padding(.vertical, 12)
    .contentShape(Rectangle())
    .onTapGesture { open(n) }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(primaryRoute(n) != nil ? .isButton : [])
  }
  private func systemRow(_ n: Notice) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(n.title).font(.subheadline.weight(.semibold)).lineLimit(2)
        Spacer(minLength: 8)
        if let t = stamp(n) {
          Text(t).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
      }
      ReplyRichText(nodes: NoticeMarkup.nodes(n.text)).font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 12)
  }
  private var prompt: String {
    guard let m = pending?.mute else { return "删除这条通知？" }
    return m ? "停止接收这条内容的新点赞通知？" : "重新接收这条内容的点赞通知？"
  }
  @MainActor private func change(_ a: Action) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      try await BiliAPI.shared.changeNotice(kind, id: a.number, uid: a.uid, mute: a.mute)
      revision += 1
    } catch { issue = error.localizedDescription }
  }
}
