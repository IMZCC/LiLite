import SwiftUI

struct DynamicCard: View {
  let entry: DynamicEntry
  var inside = false
  var openPanel: ((MomentPanel) -> Void)? = nil
  var changed: () -> Void = {}
  init(entry: DynamicEntry, inside: Bool = false, changed: @escaping () -> Void = {}) {
    self.entry = entry
    self.inside = inside
    self.changed = changed
  }
  init(
    entry: DynamicEntry, inside: Bool, openPanel: @escaping (MomentPanel) -> Void,
    changed: @escaping () -> Void
  ) {
    self.init(entry: entry, inside: inside, changed: changed)
    self.openPanel = openPanel
  }
  @EnvironmentObject var accounts: AccountContext
  @Environment(\.dismiss) var dismiss
  @AppStorage("social.dispute") private var showDispute = false
  @AppStorage("social.interaction") private var showInteraction = true
  @AppStorage("social.actionBar") private var actionBar = true
  @State private var repost = false
  @State private var editing = false
  @State private var visibility: VisibilityRequest?
  @State private var removing = false
  @State private var hidden = false
  @State private var likedReceipt: Bool?
  @AppStorage(RecommendationRules.key) private var localRules = Data()
  @State private var busy = false
  @State private var issue: String?
  var body: some View {
    let blocked =
      entry.authorID.map { mid in
        RecommendationRules.read(localRules).blockedCreators
          .contains(mid) == true
      } ?? false
    if !hidden && !blocked { card }
  }
  @ViewBuilder private var actions: some View { actionItems(primary: true) }
  /// `primary` includes comment / like / repost, which the icon bar already shows directly.
  @ViewBuilder private func actionItems(primary: Bool) -> some View {
    if !inside { NavigationLink("详情") { DynamicDetail(id: entry.id) }.piliTapFeedback() }
    if let openPanel { Button("互动记录") { openPanel(.reposts) } }
    if primary, let oid = entry.replyOID, let kind = entry.replyType {
      if let openPanel {
        Button("评论") { TouchFeedback.light(); openPanel(.replies) }
      } else {
        NavigationLink("评论") { Discussion(oid: oid, type: kind, owner: entry.authorID) }.piliTapFeedback()
      }
    }
    if primary, let uid = accounts.state.active {
      if likedReceipt == nil
        && (accounts.state.owner(.role(.heartbeat)) != uid
          || accounts.state.owner(.role(.recommend)) != uid)
      {
        Menu("点赞") {
          Button("点赞") { Task { await thumb(true, user: uid) } }
          Button("取消点赞") { Task { await thumb(false, user: uid) } }
        }.disabled(busy)
      } else {
        Button((likedReceipt ?? entry.liked) ? "已赞" : "赞") {
          Task { await thumb(!(likedReceipt ?? entry.liked), user: uid) }
        }.disabled(busy)
      }
      Button("转发") { repost = true }
    }
    if let url = URL(string: "https://t.bilibili.com/" + entry.id) {
      Menu {
        ShareLink(item: url)
        if !entry.blockedAttachment, let kind = entry.replyType, [11, 12, 17].contains(kind),
          let resource = (kind == 17 ? entry.id : entry.shareResource), !resource.isEmpty
        {
          IMShareButton(
            card: .init(
              kind == 17 ? .dynamic : kind == 12 ? .article : .album, id: resource,
              title: entry.body.isEmpty ? entry.author + "的动态" : entry.body, author: entry.author,
              authorID: entry.authorID.map(String.init),
              thumb: kind == 17 ? entry.authorFace : entry.pictures.first))
        }
        NavigationLink("保存动态图片") { SharePoster(content: .moment(entry, link: url)) }
        if let bvid = entry.laterBVID, let uid = accounts.state.active {
          Button("加入稍后再看") { Task { await addLater(bvid, user: uid) } }.disabled(busy)
        }
      } label: {
        Image(systemName: "square.and.arrow.up").accessibilityLabel("分享动态")
      }
    }
    if let mid = entry.authorID {
      Menu {
        Button("本次隐藏这位 UP 主") {
          MomentSessionHides.shared.hide(mid, name: entry.author, owner: accounts.state.active)
          hidden = true
          if inside { dismiss() }
        }
      } label: {
        Image(systemName: "eye.slash").accessibilityLabel("隐藏动态")
      }
    }
    if let mid = entry.authorID, String(mid) != accounts.state.active {
      if let uid = accounts.state.active {
        NavigationLink {
          CommunityReport(target: .moment(id: entry.id, author: mid), uid: uid) {
            hidden = true
          }
        } label: {
          Image(systemName: "exclamationmark.bubble").accessibilityLabel("举报动态")
        }
      } else {
        LocalMute(mid: mid) { hidden = true }.labelStyle(.iconOnly)
      }
    }
    if let mid = entry.authorID, let uid = accounts.state.active, String(mid) == uid {
      Menu {
        NavigationLink("可见范围与评论") { MomentOwnerSettings(entry: entry, uid: uid, changed: changed) }
        Button("编辑动态") { editing = true }
        Button("检查公开可见性") {
          if let uid = accounts.state.active {
            visibility = VisibilityRequest(.moment(entry.id), user: uid)
          }
        }
        Button(entry.pinned ? "取消置顶" : "置顶") {
          Task {
            await action(
              "/x/dynamic/feed/space/" + (entry.pinned ? "rm_top" : "set_top"),
              ["dyn_str": entry.id], user: uid)
          }
        }
        Button("删除", role: .destructive) { removing = true }
      } label: {
        Image(systemName: "ellipsis")
      }
    }
  }
  private func compact(_ n: Int64?) -> String {
    guard let n, n > 0 else { return "" }
    return n.formatted(.number.notation(.compactName))
  }
  private func barItem(_ symbol: String, _ value: String, _ label: String) -> some View {
    HStack(spacing: 5) {
      Image(systemName: symbol).font(.system(size: 16, weight: .medium))
      if !value.isEmpty { Text(value).font(.footnote).monospacedDigit() }
    }
    .frame(minWidth: 44, minHeight: 36, alignment: .leading).padding(.trailing, 14)
    .contentShape(Rectangle()).accessibilityLabel(label)
  }
  @ViewBuilder private var iconBar: some View {
    HStack(spacing: 0) {
      if let oid = entry.replyOID, let kind = entry.replyType {
        if let openPanel {
          Button { TouchFeedback.light(); openPanel(.replies) } label: {
            barItem("bubble.left", compact(entry.commentCount), "评论")
          }
        } else {
          NavigationLink { Discussion(oid: oid, type: kind, owner: entry.authorID) } label: {
            barItem("bubble.left", compact(entry.commentCount), "评论")
          }
        }
      }
      if accounts.state.active != nil {
        Button { repost = true } label: {
          barItem("arrow.2.squarepath", compact(entry.forwardCount), "转发")
        }
      }
      if let uid = accounts.state.active {
        let liked = likedReceipt ?? entry.liked
        let shown = (entry.likeCount ?? 0) + (likedReceipt.map { $0 == entry.liked ? 0 : ($0 ? 1 : -1) } ?? 0)
        if likedReceipt == nil
          && (accounts.state.owner(.role(.heartbeat)) != uid
            || accounts.state.owner(.role(.recommend)) != uid)
        {
          Menu {
            Button("点赞") { Task { await thumb(true, user: uid) } }
            Button("取消点赞") { Task { await thumb(false, user: uid) } }
          } label: { barItem("heart", compact(entry.likeCount), "点赞") }.disabled(busy)
        } else {
          Button {
            TouchFeedback.light()
            Task { await thumb(!liked, user: uid) }
          } label: {
            barItem(liked ? "heart.fill" : "heart", compact(shown), liked ? "取消点赞" : "点赞")
              .foregroundStyle(liked ? Color.pink : Color.secondary)
              .contentTransition(.symbolEffect(.replace))
          }.disabled(busy)
        }
      }
      Spacer(minLength: 0)
      Menu {
        actionItems(primary: false)
      } label: {
        Image(systemName: "ellipsis").font(.system(size: 16, weight: .medium))
          .frame(width: 44, height: 36).contentShape(Rectangle())
      }.accessibilityLabel("更多操作")
    }
    .buttonStyle(.plain).foregroundStyle(.secondary).padding(.top, 2)
  }
  private var authorHeader: some View {
    HStack(spacing: 10) {
      ReplyAvatar(member: entry.signature, size: 40)
      VStack(alignment: .leading, spacing: 2) {
        ReplyAuthorLabel(member: entry.signature, showsAvatar: false)
          .font(.subheadline.weight(.medium)).lineLimit(1)
        if !entry.date.isEmpty {
          Text(entry.date).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
    }.contentShape(Rectangle())
  }
  /// One picture shows large; two or four sit in a 2-up grid; anything else in a 3-up grid.
  @ViewBuilder private var mediaGrid: some View {
    let photos = entry.media
    if photos.count == 1 {
      GalleryLink(photos, index: 0) {
        Color.clear.aspectRatio(4 / 3, contentMode: .fit)
          .overlay { GalleryThumb(photo: photos[0], fill: true) }
          .background(.quaternary)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .frame(maxWidth: 280, alignment: .leading)
      }.buttonStyle(.plain)
    } else {
      let columns = photos.count == 2 || photos.count == 4 ? 2 : 3
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4
      ) {
        ForEach(photos.indices, id: \.self) { i in
          GalleryLink(photos, index: i) {
            Color.clear.aspectRatio(1, contentMode: .fit)
              .overlay { GalleryThumb(photo: photos[i], fill: true) }
              .background(.quaternary)
              .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          }.buttonStyle(.plain)
        }
      }
      .frame(maxWidth: columns == 2 ? 300 : .infinity, alignment: .leading)
    }
  }
  private var card: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 10) {
        Group {
          if entry.authorNavigable, let mid = entry.authorID, mid > 0 {
            NavigationLink {
              CreatorSpace(mid: mid, name: entry.author)
            } label: {
              authorHeader
            }.buttonStyle(.plain).piliTapFeedback()
          } else {
            authorHeader
          }
        }
        Spacer(minLength: 0)
        if !inside, let tag = entry.tag, !tag.isEmpty {
          Text(tag).font(.caption2.weight(.medium)).foregroundStyle(.tint)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
        } else {
          ReplyCardBadge(card: entry.signature.card)
        }
      }
      if let topic = entry.topic {
        NavigationLink { TopicFeed(topic: topic) } label: {
          Label(topic.name, systemImage: "number").font(.footnote.weight(.medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.1), in: Capsule())
        }.buttonStyle(.plain).foregroundStyle(.tint)
      }
      if showDispute, let notice = entry.presentation.notice {
        VStack(alignment: .leading) {
          Label(notice.title, systemImage: "exclamationmark.triangle")
          if !notice.body.isEmpty { Text(notice.body) }
          if let url = notice.link { NavigationLink("查看说明") { SitePage(url: url) } }
        }.font(.footnote).foregroundStyle(.secondary)
      }
      if !entry.bodyNodes.isEmpty {
        DynamicRichContent(
          nodes: entry.bodyNodes, maxLines: inside ? 0 : 8, permitsPreview: inside,
          dynamicID: entry.id)
      } else if !entry.body.isEmpty {
        Text(entry.body).textSelection(.enabled)
      }
      if entry.hasOpus {
        NavigationLink { ArticleReader(opus: entry.id) } label: {
          HStack(spacing: 3) {
            Text("阅读图文")
            Image(systemName: "chevron.right").font(.caption2.weight(.bold))
          }.font(.footnote.weight(.medium))
        }.buttonStyle(.plain).foregroundStyle(.tint).piliTapFeedback()
      }
      if !entry.blockedAttachment && !entry.media.isEmpty { mediaGrid }
      if !entry.blockedAttachment, let video = entry.video { VideoLink(video: video) }
      if !entry.blockedAttachment, let a = entry.presentation.attachment {
        NavigationLink {
          LinkDestination(item: a.route)
        } label: {
          HStack {
            if let cover = a.cover {
              SiteThumbnail(url: cover) {
                $0.resizable().scaledToFill()
              } placeholder: {
                Color.clear
              }.frame(width: 88, height: 56).clipped().clipShape(RoundedRectangle(cornerRadius: NativeGlass.thumbRadius, style: .continuous))
            }
            Text(a.title).lineLimit(2).foregroundStyle(.primary).multilineTextAlignment(.leading)
              .frame(maxWidth: .infinity, alignment: .leading)
          }.contentShape(Rectangle())
        }
      }
      MomentResourceViews(values: entry.resources, dynamic: entry.id)
      if showInteraction && !inside && !entry.interactionLines.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(Array(entry.interactionLines.enumerated()), id: \.offset) { _, line in
            HStack(alignment: .top) {
              Image(systemName: line.type == 1 ? "text.bubble" : "hand.thumbsup")
              ReplyRichText(
                nodes: line.nodes, maxLines: 3, permitsPreview: false, dynamicID: entry.id,
                textStyle: .footnote)
            }
          }
        }.font(.footnote).foregroundStyle(.secondary)
      }
      if let orig = entry.originalID, orig != entry.id {
        VStack(alignment: .leading, spacing: 8) {
          if let src = entry.originalAuthor {
            if let mid = entry.originalAuthorID, mid > 0 {
              NavigationLink {
                CreatorSpace(mid: mid, name: src.uname ?? "用户空间")
              } label: {
                ReplyAuthorLabel(member: src, showsAvatar: false).font(.subheadline.weight(.medium))
                  .foregroundStyle(.tint)
              }.buttonStyle(.plain).piliTapFeedback()
            } else {
              ReplyAuthorLabel(member: src, showsAvatar: false).font(.subheadline.weight(.medium))
            }
          }
          if let r = entry.originalResources { MomentResourceViews(values: r, dynamic: orig) }
          if !entry.originalNodes.isEmpty {
            DynamicRichContent(
              nodes: entry.originalNodes, maxLines: inside ? 0 : 5, permitsPreview: false,
              dynamicID: orig)
          }
          NavigationLink { DynamicDetail(id: orig) } label: {
            HStack(spacing: 3) {
              Text(entry.originalNodes.isEmpty ? (entry.summary ?? "查看原动态") : "查看原动态")
                .lineLimit(2).multilineTextAlignment(.leading)
              Image(systemName: "chevron.right").font(.caption2.weight(.bold))
            }.font(.footnote)
          }.buttonStyle(.plain).foregroundStyle(.secondary).piliTapFeedback()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground),
          in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      }
      if !entry.blockedAttachment, let vote = entry.voteID {
        NavigationLink("查看投票") { VoteView(id: vote, dynamic: entry.id) }
      }
      if !inside || actionBar {
        iconBar
      } else {
        Menu {
          actions
        } label: {
          Label("操作", systemImage: "ellipsis.circle")
        }
      }
    }.padding(.vertical, 12)
      .onChange(of: accounts.state.active) { _, _ in
        likedReceipt = nil
        issue = nil
      }
      .onChange(of: entry.liked) { _, _ in likedReceipt = nil }
      .piliSheet(item: $visibility) { VisibilityPanel(request: $0) }
      .piliSheet(isPresented: $editing) {
        if let uid = accounts.state.active, uid == entry.authorID.map(String.init) {
          DynamicEditView(id: entry.id, uid: uid, changed: changed)
        }
      }
      .piliSheet(isPresented: $repost) { DynamicComposer(repost: entry.id) { changed() } }
      .confirmationDialog("删除这条动态？", isPresented: $removing) {
        Button("删除", role: .destructive) {
          guard let uid = accounts.state.active, entry.authorID.map(String.init) == uid else {
            return
          }
          Task {
            await action(
              "/x/dynamic/feed/operate/remove", ["dyn_id_str": entry.id], user: uid, remove: true)
          }
        }
      }
      .alert("动态", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
        Button("好") {}
      } message: {
        Text(issue ?? "")
      }
  }
  @MainActor private func addLater(_ bvid: String, user uid: String) async {
    guard !busy, uid == accounts.state.active else { return }
    busy = true
    defer { busy = false }
    do {
      try await BiliAPI.shared.submit(
        "/x/v2/history/toview/add", ["bvid": bvid], expectedAccount: uid)
      if uid == accounts.state.active { issue = "已加入稍后再看" }
    } catch { if uid == accounts.state.active { issue = error.localizedDescription } }
  }
  @MainActor private func thumb(_ add: Bool, user uid: String) async {
    guard !busy, accounts.state.active == uid else { return }
    TouchFeedback.light()
    busy = true
    defer { busy = false }
    do {
      let row = try await BiliAPI.shared.mainDynamicRow(entry.id, owner: uid)
      guard accounts.state.active == uid else { return }
      guard let before = MomentResources.likeStatus(row) else { throw ServiceError("未能读取点赞状态") }
      if before != add {
        _ = try await BiliAPI.shared.dynPost(
          "/x/dynamic/feed/dyn/thumb",
          ["dyn_id_str": entry.id, "up": add ? 1 : 2, "spmid": "333.1365.0.0"], expectedAccount: uid
        )
      }
      guard accounts.state.active == uid else { return }
      likedReceipt = add
      changed()
    } catch { if accounts.state.active == uid { issue = error.localizedDescription } }
  }
  private func action(_ path: String, _ body: [String: Any], user uid: String, remove: Bool = false)
    async
  {
    guard !busy, accounts.state.active == uid else { return }
    busy = true
    defer { busy = false }
    do {
      let row = try await BiliAPI.shared.mainDynamicRow(entry.id, owner: uid)
      guard accounts.state.active == uid, let source = DynamicEntry(row),
        source.authorID.map(String.init) == uid
      else { throw ServiceError("只能管理自己的动态") }
      if !remove && source.tag != nil && source.pinned == path.hasSuffix("/set_top") {
        changed()
        return
      }
      _ = try await BiliAPI.shared.dynPost(path, body, expectedAccount: uid)
      guard accounts.state.active == uid else { return }
      if remove { hidden = true }
      changed()
      if remove && inside { dismiss() }
    } catch { issue = error.localizedDescription }
  }
}
struct DynamicDetail: View {
  let id: String
  var byAlbum = false, privateOwner: String? = nil, resolveArticle = false
  @EnvironmentObject private var accounts: AccountContext
  @State private var revision = 0
  @State private var entry: DynamicEntry?
  @State private var error: String?
  @State private var selected = MomentPanel.replies
  @State private var counts: [MomentPanel: Int64] = [:]
  @State private var jump = 0
  private func picker(_ d: DynamicEntry) -> AnyView {
    AnyView(
      ChipBar(items: MomentPanel.allCases, selection: $selected, title: { kind in
        let value =
          counts[kind]
          ?? (kind == .replies ? d.commentCount : kind == .likes ? d.likeCount : d.forwardCount)
        return kind.rawValue + (value.map { " " + $0.formatted(.number.notation(.compactName)) } ?? "")
      })
      .padding(.vertical, 4)
      .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear))
  }
  var body: some View {
    let user = accounts.state.active
    let source = accounts.state.owner(.role(.heartbeat))
    Group {
      if let d = entry, resolveArticle, d.replyType == 12 {
        ArticleReader(opus: d.id)
      } else if let d = entry {
        ScrollViewReader { proxy in
          ReadingSplit(hasPanel: true) {
            DynamicCard(
              entry: d, inside: true,
              openPanel: { kind in
                selected = kind
                jump += 1
              }
            ) { revision += 1 }
          } panel: { header in
            let bar = picker(d)
            if selected == .replies {
              if let oid = d.replyOID, let kind = d.replyType {
                Discussion(
                  oid: oid, type: kind, owner: d.authorID, embeddedTitle: "动态详情",
                  readingHeader: header, readingControls: bar,
                  readingCount: { counts[.replies] = $0 })
              } else {
                ScrollView {
                  VStack(alignment: .leading) {
                    if let header { header }
                    bar.id("pili.page.controls")
                    ContentUnavailableView("评论暂不可用", systemImage: "text.bubble")
                  }.padding(.horizontal)
                }
              }
            } else {
              let which = selected
              DynamicActivityList(
                id: d.id, panel: which, heading: header, controls: bar, title: "动态详情",
                updated: { counts[which] = $0 })
            }
          }
          .onChange(of: selected) { _, _ in jump += 1 }
          .onChange(of: jump) { _, _ in
            DispatchQueue.main.async {
              withAnimation { proxy.scrollTo("pili.page.controls", anchor: .top) }
            }
          }
        }
      } else if let error {
        ContentUnavailableView {
          Label("动态未能加载", systemImage: "text.bubble")
        } description: {
          Text(error)
        } actions: {
          Button("重试") { revision += 1 }
        }
      } else {
        PageLoading()
      }
    }.navigationTitle(resolveArticle && entry?.replyType == 12 ? "阅读" : "动态详情").navigationBarTitleDisplayMode(.inline)
      .linkedDiscussion(oid: entry?.replyOID, type: entry?.replyType ?? 0, author: entry?.authorID)
      .task(id: "\(id):\(byAlbum):\(privateOwner ?? ""):\(user ?? ""):\(source ?? ""):\(revision)")
    {
      error = nil
      do {
        let result: DynamicEntry
        if let privateOwner {
          guard privateOwner == user else { throw ServiceError("账号已切换") }
          let row = try await BiliAPI.shared.mainDynamicRow(id, owner: privateOwner)
          guard let d = DynamicEntry(row), d.authorID.map(String.init) == privateOwner else {
            throw ServiceError("无法核实动态作者")
          }
          result = d
        } else {
          result = try await BiliAPI.shared.dynamic(
            id, byAlbum: byAlbum, expectedAccount: source ?? "")
        }
        try Task.checkCancellation()
        guard accounts.state.active == user, accounts.state.owner(.role(.heartbeat)) == source
        else { return }
        entry = result
        counts = [:]
        error = nil
      } catch {
        if !Task.isCancelled, accounts.state.active == user {
          self.error = error.localizedDescription
          entry = nil
        }
      }
    }.onChange(of: "\(id):\(byAlbum):\(user ?? ""):\(source ?? "")") { _, _ in
      entry = nil
      error = nil
      counts = [:]
      selected = .replies
    }
  }
}
struct TopicDirectory: View {
  var select: ((TopicLink) -> Void)? = nil
  @State private var input = ""
  @State private var term = ""
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    let search = select != nil || !term.isEmpty
    let owner = search ? accounts.state.active : accounts.state.owner(.role(.recommend))
    PageList(empty: "暂无话题") { cursor in
      let page = max(1, Int(cursor ?? "") ?? 1)
      var q = ["web_location": "333.1365"]
      if search {
        q["keywords"] = term
        q["content"] = ""
        if page == 1 {
          q["page_num"] = "1"
          q["page_size"] = "20"
        } else {
          q["offset"] = String((page - 1) * 20)
        }
      } else {
        q["source"] = "Web"
        q["page_size"] = "25"
      }
      return try await BiliAPI.shared.topicIndex(
        search: search, fields: q, owner: owner ?? "", page: page)
    } row: { t in
      if let select {
        Button {
          select(t)
        } label: {
          label(t)
        }
      } else {
        PlainRowLink {
          TopicFeed(topic: t)
        } label: {
          label(t)
        }
      }
    }.id("\(term):\(owner ?? "")")
      .navigationTitle(select == nil ? "动态话题" : "选择话题").searchable(text: $input, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索话题")
      .onSubmit(of: .search) { term = input.trimmingCharacters(in: .whitespacesAndNewlines) }
      .task(id: input) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { try? await Task.sleep(nanoseconds: 300_000_000) }
        if !Task.isCancelled { term = value }
      }
  }
  private func label(_ topic: TopicLink) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(topic.name, systemImage: "number")
      if topic.view != nil || topic.discuss != nil {
        Text(
          "\((topic.view ?? 0).formatted(.number.notation(.compactName))) 浏览 · \((topic.discuss ?? 0).formatted(.number.notation(.compactName))) 讨论"
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
struct CreatorDynamics: View {
  let mid: Int64
  @EnvironmentObject private var accounts:AccountContext
  @AppStorage("social.hideGoods") private var goods=false
  @AppStorage("social.dynamicRegex") private var pattern=""
  @State private var rev = 0
  var body: some View {
    PageList(empty: "暂无动态", dynamicCards: true) { cursor in
      try await BiliAPI.shared.dynamics(offset:cursor,author:mid,user:accounts.state.active ?? "")
    } row: { d in
      DynamicCard(entry: d) { rev += 1 }
    }.id("\(mid):\(accounts.state.active ?? ""):\(goods):\(pattern):\(rev)").navigationTitle("空间动态")
  }
}
