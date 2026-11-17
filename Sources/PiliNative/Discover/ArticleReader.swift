import SwiftUI

struct ReadingDocument {
  var title = "专栏", author = "", blocks: [ArticleBlock] = []
  struct Community: Identifiable {
    let id: Int64, name: String, face: URL?, detail: String, url: URL?
  }
  var communities: [Community] = []
  var collectionTitle: String?, collectionInfo: String?
  var lead: [GalleryPicture] = []
  var shareCover: URL?, published: Int64?, restriction: ArticleResource?
  var comments: Int64?, forwards: Int64?
  var signature: ReplyAuthor?, liked: Bool?, favorite: Bool?, likes: Int64?, favorites: Int64?
  static func number(_ value: Any?) -> Int64? {
    (value as? NSNumber)?.int64Value ?? (value as? String).flatMap(Int64.init)
  }
  static func flag(_ value: Any?) -> Bool? {
    switch value {
    case let n as NSNumber: return n.boolValue
    case let s as String:
      if ["1", "STATE_LIKE", "true"].contains(s) { return true }
      if ["0", "STATE_NONE", "STATE_UNLIKE", "false"].contains(s) { return false }
      return nil
    default: return nil
    }
  }
  var authorID: Int64?, collection: Int64?, commentID: Int64?, commentType = 12
  var opus: String?, article: Int64?
}
extension BiliAPI {
  func reading(article: Int64, expectedAccount: String? = nil, resolveRedirect: Bool = true)
    async throws -> ReadingDocument
  {
    guard article > 0 else { throw ServiceError("专栏编号无效") }
    if resolveRedirect {
      let origin = URL(string: "https://www.bilibili.com/read/cv\(article)/")!
      var head = URLRequest(url: origin, timeoutInterval: 5)
      head.httpMethod = "HEAD"
      head.httpShouldHandleCookies = false
      if let (_, res) = try? await session.data(for: head), let h = res as? HTTPURLResponse {
        let location =
          h.value(forHTTPHeaderField: "Location").flatMap {
            URL(string: $0, relativeTo: origin)?.absoluteURL
          } ?? h.url
        if let u = location, case .opus(let op) = SharedLink.parse(u.absoluteString) {
          return try await reading(opus: op, expectedAccount: expectedAccount)
        }
      }
      try Task.checkCancellation()
    }
    let d = try await dynamicData(
      "/x/article/view",
      try await sign(["id": String(article), "gaia_source": "main_web", "web_location": "333.976"]),
      expectedAccount: expectedAccount)
    var doc = ReadingDocument()
    if let actual = ReadingDocument.number(d["id"]), actual != article {
      throw ServiceError("专栏编号不匹配")
    }
    doc.published = ReadingDocument.number(d["publish_time"])
    doc.shareCover = (d["origin_image_urls"] as? [String])?.first.flatMap(GalleryPicture.source)
    doc.article = article
    doc.commentID = article
    doc.title = d["title"] as? String ?? "专栏"
    doc.opus = d["dyn_id_str"] as? String
    let author = d["author"] as? ArticleBody.Object
    doc.author = author?["name"] as? String ?? ""
    doc.authorID = ReadingDocument.number(author?["mid"])
    doc.signature = author.map(ReplyAuthor.init(dynamic:))
    doc.collection = ((d["list"] as? ArticleBody.Object)?["id"] as? NSNumber)?.int64Value
    if let p = ((d["opus"] as? ArticleBody.Object)?["content"] as? ArticleBody.Object)?[
      "paragraphs"] as? [ArticleBody.Object]
    {
      doc.blocks = ArticleBody.opus(p)
    }
    if doc.blocks.isEmpty, ReadingDocument.number(d["type"]) == 3 {
      if let ops = d["ops"] as? [ArticleBody.Object] {
        doc.blocks = ArticleBody.legacyOps(ops)
      } else if let raw = d["content"] as? String, let data = raw.data(using: .utf8),
        let parsed = try? JSONSerialization.jsonObject(with: data)
      {
        let ops =
          (parsed as? [ArticleBody.Object]) ?? (parsed as? ArticleBody.Object)?["ops"]
          as? [ArticleBody.Object] ?? []
        doc.blocks = ArticleBody.legacyOps(ops)
      }
    }
    if doc.blocks.isEmpty, ReadingDocument.number(d["type"]) != 3,
      let html = d["content"] as? String
    {
      doc.blocks = ArticleBody.html(html)
    }
    guard !doc.blocks.isEmpty else { throw ServiceError("专栏正文暂不可用") }
    if let info = try? await dynamicData(
      "/x/article/viewinfo",
      try await sign([
        "id": String(article), "mobi_app": "pc", "from": "web", "gaia_source": "main_web",
      ]),
      expectedAccount: expectedAccount)
    {
      if doc.title == "专栏", let t = info["title"] as? String { doc.title = t }
      if doc.shareCover == nil {
        doc.shareCover = (info["origin_image_urls"] as? [String])?.first.flatMap(
          GalleryPicture.source)
      }
      let stats = info["stats"] as? ArticleBody.Object
      doc.favorite = ReadingDocument.flag(info["favorite"])
      doc.liked = ReadingDocument.flag(info["is_like"] ?? info["like"])
      doc.likes = ReadingDocument.number(stats?["like"])
      doc.favorites = ReadingDocument.number(stats?["favorite"])
      doc.comments = ReadingDocument.number(stats?["reply"])
      doc.forwards = ReadingDocument.number(stats?["share"])
    }
    return doc
  }
  func reading(opus: String, expectedAccount: String? = nil) async throws -> ReadingDocument {
    typealias Map = ArticleBody.Object
    let d = try await dynamicData(
      "/x/polymer/web-dynamic/v1/opus/detail",
      try await sign([
        "id": opus, "timezone_offset": String(-TimeZone.current.secondsFromGMT() / 60),
        "features": "htmlNewStyle,articleEnhance,cardsEnhance,ugcDelete,editable",
      ]), expectedAccount: expectedAccount)
    if let aid = ReadingDocument.number((d["fallback"] as? Map)?["id"]), aid > 0 {
      return try await reading(
        article: aid, expectedAccount: expectedAccount, resolveRedirect: false)
    }
    guard let item = d["item"] as? Map, let modules = item["modules"] as? [Map] else {
      throw ServiceError("图文暂不可用")
    }
    var doc = ReadingDocument()
    if let actual = item["id_str"] as? String, actual != opus { throw ServiceError("图文编号不匹配") }
    doc.opus = opus
    doc.title = "图文"
    if let basic = item["basic"] as? Map {
      if let oid = ReadingDocument.number(basic["comment_id_str"]), oid > 0,
        let type = ReadingDocument.number(basic["comment_type"]).flatMap(Int.init(exactly:)),
        type > 0
      {
        doc.commentID = oid
        doc.commentType = type
      }
    }
    for m in modules {
      if let b = m["module_blocked"] as? Map {
        let button = b["button"] as? Map
        let url = (button?["jump_url"] as? String).flatMap(httpsURL)
        doc.restriction = .init(
          title: b["title"] as? String ?? "内容受限",
          detail: [b["hint_message"] as? String, button?["text"] as? String].compactMap { $0 }
            .joined(separator: " · "), cover: nil, target: url.map(RichNode.Target.url))
      }
      if let t = (m["module_title"] as? Map)?["text"] as? String { doc.title = t }
      if let a = m["module_author"] as? Map {
        doc.published = ReadingDocument.number(a["pub_ts"])
        doc.author = a["name"] as? String ?? ""
        doc.authorID = ReadingDocument.number(a["mid"])
        doc.signature = ReplyAuthor(dynamic: a)
      }
      if let display = (m["module_top"] as? Map)?["display"] as? Map,
        let pics = (display["album"] as? Map)?["pics"] as? [Map]
      {
        doc.lead = pics.compactMap(GalleryPicture.init)
      }
      if let stats = m["module_stat"] as? Map {
        doc.comments = ReadingDocument.number((stats["comment"] as? Map)?["count"])
        doc.forwards = ReadingDocument.number((stats["forward"] as? Map)?["count"])
        let like = stats["like"] as? Map
        let favorite = stats["favorite"] as? Map
        doc.liked = ReadingDocument.flag(like?["status"])
        doc.favorite = ReadingDocument.flag(favorite?["status"])
        doc.likes = ReadingDocument.number(like?["count"])
        doc.favorites = ReadingDocument.number(favorite?["count"])
      }
      if let tribes = (m["module_tribee"] as? Map)?["items"] as? [Map] {
        doc.communities = tribes.compactMap { t in
          guard let id = ReadingDocument.number(t["tribee_id"]), id > 0,
            let name = t["name"] as? String
          else { return nil }
          return ReadingDocument.Community(
            id: id, name: name + (t["suffix"] as? String ?? ""),
            face: (t["face_url"] as? String).flatMap(GalleryPicture.source),
            detail: [t["dyn_count_text"] as? String, t["latest_time_text"] as? String].compactMap {
              $0
            }.joined(separator: " · "), url: (t["jump_url"] as? String).flatMap(httpsURL))
        }
      }
      if let c = m["module_collection"] as? Map {
        doc.collectionTitle = c["title"] as? String
        doc.collectionInfo = [c["name"] as? String, c["count"] as? String].compactMap { $0 }.joined(
          separator: " · ")
        doc.collection =
          (c["id"] as? NSNumber)?.int64Value ?? (c["id"] as? String).flatMap(Int64.init)
      }
      if let list = (m["module_content"] as? Map)?["paragraphs"] as? [Map] {
        doc.blocks += ArticleBody.opus(list)
      }
    }
    if let restriction = doc.restriction {
      doc.blocks = [.card(restriction)]
      doc.lead = []
      doc.commentID = nil
      doc.communities = []
      doc.collection = nil
      return doc
    }
    guard !doc.blocks.isEmpty || !doc.lead.isEmpty else { throw ServiceError("这篇图文暂无可显示的正文") }
    return doc
  }
}
struct ArticleReader: View {
  let id: Int64?, opus: String?
  var isNotebook = false
  init(note: Int64) {
    id = note
    opus = nil
    isNotebook = true
  }
  init(id: Int64) {
    self.id = id
    opus = nil
  }
  init(opus: String) {
    id = nil
    self.opus = opus
  }
  @EnvironmentObject private var accounts: AccountContext
  @State private var doc: ReadingDocument?
  @State private var pictures: [GalleryPicture] = []
  @State private var pictureIndices: [GalleryPicture: Int] = [:]
  @State private var error: String?
  @State private var actionError: String?
  @State private var retry = 0
  @State private var incoming: IncomingRoute?
  @State private var saving = false
  @State private var jump = 0
  @State private var reposting = false
  @State private var leadPage = 0
  @AppStorage("social.actionBar") private var showActions = true
  @State private var historyVisit: String?
  private var publicURL: URL? {
    if let article = doc?.article { return URL(string: "https://www.bilibili.com/read/cv\(article)") }
    if let op = doc?.opus { return URL(string: "https://www.bilibili.com/opus/" + op) }
    if let id { return URL(string: "https://www.bilibili.com/read/cv\(id)") }
    return opus.flatMap { URL(string: "https://www.bilibili.com/opus/" + $0) }
  }
  private func story(_ article: ReadingDocument) -> some View {
    LazyVStack(alignment: .leading, spacing: 15) {
      if !article.lead.isEmpty {
        ThresholdPager(count: article.lead.count, page: $leadPage, indicators: true) { i in
          GalleryLink(article.lead, index: i) { GalleryThumb(photo: article.lead[i]) }
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: NativeGlass.cardRadius, style: .continuous))
        .onChange(of: article.lead.count, initial: true) { _, n in
          leadPage = max(0, min(leadPage, n - 1))
        }
      }
      Text(article.title).font(.title2.weight(.bold)).lineSpacing(3).textSelection(.enabled)
      Group {
        if let mid = article.authorID {
          NavigationLink {
            CreatorSpace(mid: mid, name: article.author)
          } label: {
            authorLine(article)
          }.buttonStyle(.plain)
        } else {
          authorLine(article)
        }
      }
      ForEach(article.communities) { c in
        NavigationLink {
          if let u = c.url, let r = SharedLink.parse(u.absoluteString) {
            LinkDestination(item: r)
          } else if let url = c.url {
            SitePage(url: url)
          } else {
            BubbleCommunity(id: c.id)
          }
        } label: {
          HStack(spacing: 10) {
            if let u = c.face {
              SiteThumbnail(url: u) {
                $0.resizable().scaledToFill()
              } placeholder: {
                Color.clear
              }.frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
              Text(c.name).font(.subheadline.weight(.medium))
              if !c.detail.isEmpty {
                Text(c.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
          }
          .padding(10)
          .background(Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }.buttonStyle(.plain)
      }
      if let collection = article.collection {
        NavigationLink {
          ArticleCollection(id: collection)
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "books.vertical.fill").font(.body).foregroundStyle(.tint)
              .frame(width: 34, height: 34)
              .background(Color.accentColor.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
              Text(article.collectionTitle ?? "查看文集").font(.subheadline.weight(.medium))
              if let descr = article.collectionInfo, !descr.isEmpty {
                Text(descr).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
          }
          .padding(10)
          .background(Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }.buttonStyle(.plain)
      }
      Divider().padding(.vertical, 2)
      ForEach(article.blocks.indices, id: \.self) { index in content(article.blocks[index]) }
    }.padding(.vertical, 8)
  }
  private func authorLine(_ article: ReadingDocument) -> some View {
    HStack(spacing: 10) {
      if let author = article.signature {
        ReplyAvatar(member: author, size: 38)
      }
      VStack(alignment: .leading, spacing: 2) {
        if let author = article.signature {
          ReplyAuthorLabel(member: author, showsAvatar: false).font(.subheadline.weight(.medium))
        } else {
          Text(article.author.isEmpty ? "作者空间" : article.author).font(.subheadline.weight(.medium))
        }
        if let t = article.published, t > 0 {
          Text(Date(timeIntervalSince1970: Double(t)).formatted(date: .abbreviated, time: .shortened))
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
      ReplyCardBadge(card: article.signature?.card)
    }.contentShape(Rectangle())
  }
  @ViewBuilder private func actionBar(_ doc: ReadingDocument) -> some View {
    let uid = accounts.state.active
    HStack(spacing: 0) {
      if doc.opus?.isEmpty == false {
        Button {
          reposting = true
        } label: {
          stat("转发", icon: "arrowshape.turn.up.right", count: doc.forwards)
        }.disabled(uid == nil)
      }
      if let uid, let favor = doc.favorite {
        Button {
          Task { await change(doc, !favor, user: uid) }
        } label: {
          stat(favor ? "取消收藏" : "收藏", icon: favor ? "star.fill" : "star", count: doc.favorites)
        }
      } else {
        Menu {
          if let uid {
            Button("收藏") { Task { await change(doc, true, user: uid) } }
            Button("取消收藏") { Task { await change(doc, false, user: uid) } }
          }
        } label: {
          stat("收藏", icon: "star", count: doc.favorites)
        }.disabled(uid == nil)
      }
      if doc.commentID != nil {
        Button {
          jump += 1
        } label: {
          stat("评论", icon: "text.bubble", count: doc.comments)
        }
      }
      if doc.opus?.isEmpty == false {
        if let liked = doc.liked, let uid {
          Button {
            Task { await like(doc, add: !liked, user: uid) }
          } label: {
            stat(
              liked ? "取消点赞" : "点赞", icon: liked ? "hand.thumbsup.fill" : "hand.thumbsup",
              count: doc.likes)
          }
        } else {
          Menu {
            if let uid {
              Button("点赞") { Task { await like(doc, add: true, user: uid) } }
              Button("取消点赞") { Task { await like(doc, add: false, user: uid) } }
            }
          } label: {
            stat("点赞", icon: "hand.thumbsup", count: doc.likes)
          }.disabled(uid == nil)
        }
      }
    }
    .buttonStyle(.plain).foregroundStyle(.secondary)
    .padding(.horizontal, 8).frame(height: 52)
    .piliGlass(in: Capsule())
    .padding(.horizontal, 20).padding(.bottom, 6)
    .disabled(saving)
  }
  private func stat(_ label: String, icon: String, count: Int64?) -> some View {
    HStack(spacing: 5) {
      Image(systemName: icon).font(.system(size: 17, weight: .medium))
        .foregroundStyle(icon.hasSuffix(".fill") ? Color.accentColor : Color.secondary)
        .contentTransition(.symbolEffect(.replace))
      Text(count.map { $0 > 0 ? $0.formatted(.number.notation(.compactName)) : label } ?? label)
        .font(.footnote).monospacedDigit()
    }
    .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label).accessibilityValue(count.map(String.init) ?? "")
  }
  var body: some View {
    let reader = accounts.state.active
    ScrollViewReader { proxy in
      Group {
        if let doc {
          ReadingSplit(hasPanel: doc.commentID != nil) {
            story(doc)
          } panel: { header in
            if let oid = doc.commentID {
              Discussion(
                oid: oid, type: doc.commentType, owner: doc.authorID, embeddedTitle: doc.title,
                readingHeader: header, readingControls: AnyView(Text("评论").font(.headline)))
            }
          }
        } else if let error {
          ContentUnavailableView {
            Label("图文未能加载", systemImage: "doc.richtext")
          } description: {
            Text(error)
          } actions: {
            Button("重试") { retry += 1 }
          }
        } else {
          PageLoading()
        }
      }.onChange(of: jump) { _, _ in
        withAnimation { proxy.scrollTo("pili.page.controls", anchor: .top) }
      }
    }.navigationTitle(doc?.title ?? "阅读").navigationBarTitleDisplayMode(.inline)
      .linkedDiscussion(oid: doc?.commentID, type: doc?.commentType ?? 12, author: doc?.authorID).toolbar {
      if let url = publicURL {
        NavigationLink { SitePage(url: url) } label: {
          Image(systemName: "safari").accessibilityLabel("浏览器打开")
        }
      }
      if let doc {
        Menu {
          if doc.commentID != nil { Button("查看评论") { jump += 1 } }
          if let uid = accounts.state.active, doc.restriction == nil {
            if !showActions, doc.opus?.isEmpty == false { Button("转发") { reposting = true } }
            if let id = doc.opus, !id.isEmpty {
              if let liked = doc.liked {
                Button(liked ? "取消点赞" : "点赞") { Task { await like(doc, add: !liked, user: uid) } }
              } else {
                Menu("点赞") {
                  Button("点赞") { Task { await like(doc, add: true, user: uid) } }
                  Button("取消点赞") { Task { await like(doc, add: false, user: uid) } }
                }
              }
            }
            if doc.favorite != true { Button("收藏") { Task { await change(doc, true, user: uid) } } }
            if doc.favorite != false {
              Button("取消收藏") { Task { await change(doc, false, user: uid) } }
            }
          }
          if let url = publicURL {
            ShareLink(item: url)
            Button("复制链接") { UIPasteboard.general.url = url }
            if let article = doc.article ?? (doc.commentType == 12 ? doc.commentID : nil) {
              IMShareButton(
                card: .init(
                  .article, id: String(article), title: doc.title, author: doc.author,
                  authorID: doc.authorID.map(String.init),
                  thumb: pictures.first?.url))
            } else if let opus = doc.opus {
              IMShareButton(
                card: .init(
                  .dynamic, id: opus, title: doc.title, author: doc.author,
                  authorID: doc.authorID.map(String.init),
                  thumb: pictures.first?.url))
            }
            NavigationLink("生成分享卡片") {
              SharePoster(
                content: .init(
                  title: doc.title,
                  body: doc.blocks.compactMap {
                    if case .paragraph(let spans) = $0 { return spans.map(\.value).joined() }
                    return nil
                  }.prefix(2).joined(separator: "\n"),
                  author: doc.author,
                  date: doc.published.map {
                    Date(timeIntervalSince1970: Double($0)).formatted(
                      date: .abbreviated, time: .omitted)
                  } ?? "", kind: "图文", link: url,
                  cover: doc.shareCover ?? doc.lead.first?.url
                    ?? pictures.first?.url))
            }
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }.disabled(saving)
      }
    }
    .environment(
      \.openURL,
      OpenURLAction { url in
        if let r = SharedLink.parse(url.absoluteString) {
          incoming = IncomingRoute(link: r)
          return .handled
        }
        return .systemAction
      }
    )
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let doc, showActions, doc.restriction == nil { actionBar(doc) }
    }
    .piliSheet(isPresented: $reposting) {
      if let op = doc?.opus, accounts.state.active != nil {
        DynamicComposer(repost: op) {
          if doc?.opus == op, let n = doc?.forwards { doc?.forwards = n + 1 }
        }
      }
    }
    .piliSheet(item: $incoming) { r in
      PiliNavigationStack {
        LinkDestination(item: r.link).toolbar { Button("关闭") { incoming = nil } }
      }
    }
    .alert(
      "图文", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    ) {
      Button("好") {}
    } message: {
      Text(actionError ?? "")
    }
    .task(id: "\(id ?? 0):\(opus ?? ""):\(retry):\(reader ?? "")") {
      doc = nil
      pictures = []
      pictureIndices = [:]
      error = nil
      do {
        let r: ReadingDocument
        if isNotebook, let id {
          r = try await BiliAPI.shared.publishedNotebook(id, owner: reader ?? "")
        } else if let id {
          r = try await BiliAPI.shared.reading(article: id, expectedAccount: reader ?? "")
        } else if let opus {
          r = try await BiliAPI.shared.reading(opus: opus, expectedAccount: reader ?? "")
        } else {
          throw ServiceError("图文编号无效")
        }
        try Task.checkCancellation()
        guard accounts.state.active == reader else { return }
        let photos = r.blocks.compactMap(\.picture)
        var indices = [GalleryPicture: Int]()
        for (index, photo) in photos.enumerated() where indices[photo] == nil {
          indices[photo] = index
        }
        pictures = photos
        pictureIndices = indices
        doc = r
        await record(r)
      } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
  }
  @MainActor private func record(_ doc: ReadingDocument) async {
    guard let oid = doc.commentID, let uid = accounts.state.owner(.role(.heartbeat)),
      UserDefaults.standard.object(forKey: "history.sync") as? Bool != false
    else { return }
    let key = uid + ":" + String(oid)
    guard historyVisit != key else { return }
    do {
      let api = BiliAPI.shared
      let paused = try await api.read(
        "/x/v2/history/shadow", ["jsonp": "jsonp"], expectedAccount: uid, as: Bool.self)
      try Task.checkCancellation()
      guard !paused, historyVisit != key, accounts.state.owner(.role(.heartbeat)) == uid,
        UserDefaults.standard.object(forKey: "history.sync") as? Bool != false
      else { return }
      try await api.submit(
        "/x/v2/history/report", ["aid": String(oid), "type": "5"], expectedAccount: uid)
      historyVisit = key
    } catch {}
  }
  @MainActor private func like(_ d: ReadingDocument, add: Bool, user: String) async {
    guard !saving, d.restriction == nil, accounts.state.active == user, let op = d.opus else {
      return
    }
    saving = true
    defer { saving = false }
    do {
      let verified = try await BiliAPI.shared.mainDynamicRow(op, owner: user)
      guard let current = MomentResources.likeStatus(verified), accounts.state.active == user else {
        throw ServiceError("未能读取点赞状态")
      }
      if current != add {
        _ = try await BiliAPI.shared.dynPost(
          "/x/dynamic/feed/dyn/thumb",
          [
            "dyn_id_str": op,
            "up": add ? 1 : 2, "spmid": "333.1365.0.0",
          ], expectedAccount: user)
      }
      guard accounts.state.active == user, doc?.opus == op else { return }
      if let old = doc?.liked, old != add, let n = doc?.likes {
        doc?.likes = max(0, n + (add ? 1 : -1))
      }
      doc?.liked = add
      actionError = add ? "已点赞" : "已取消点赞"
    } catch { if accounts.state.active == user { actionError = error.localizedDescription } }
  }
  @MainActor private func change(_ doc: ReadingDocument, _ add: Bool, user: String) async {
    guard !saving, doc.restriction == nil, accounts.state.active == user else { return }
    saving = true
    defer { saving = false }
    do {
      if let id = doc.article {
        try await BiliAPI.shared.submit(
          "/x/article/favorites/" + (add ? "add" : "del"), ["id": String(id)], expectedAccount: user
        )
      } else if let opus = doc.opus {
        _ = try await BiliAPI.shared.dynPost(
          "/x/community/cosmo/interface/simple_action",
          ["entity": ["object_id_str": opus, "type": ["biz": 2]], "action": add ? 3 : 4],
          expectedAccount: user)
      }
      guard accounts.state.active == user, self.doc?.article == doc.article,
        self.doc?.opus == doc.opus
      else { return }
      if let old = self.doc?.favorite, old != add, let n = self.doc?.favorites {
        self.doc?.favorites = max(0, n + (add ? 1 : -1))
      }
      self.doc?.favorite = add
      actionError = add ? "已收藏" : "已取消收藏"
    } catch { actionError = error.localizedDescription }
  }
  @Environment(\.colorScheme) private var themeMode
  private func rich(_ spans: [ArticleSpan]) -> Text {
    var result = AttributedString()
    for s in spans {
      var part = AttributedString(s.value)
      var style = InlinePresentationIntent()
      if s.bold { style.insert(.stronglyEmphasized) }
      if s.italic { style.insert(.emphasized) }
      if s.strike { style.insert(.strikethrough) }
      part.inlinePresentationIntent = style
      if let size = s.fontSize, size > 0 { part.font = .system(size: min(40, max(11, size))) }
      if let rgb = s.hexRGB {
        let r = Double((rgb >> 16) & 255) / 255
        let g = Double((rgb >> 8) & 255) / 255
        let b = Double(rgb & 255) / 255
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        if (themeMode == .dark && luminance > 0.34) || (themeMode != .dark && luminance < 0.64) {
          part.foregroundColor = Color(red: r, green: g, blue: b)
        }
      }
      part.link = s.url
      result += part
    }
    return Text(result)
  }
  @ViewBuilder private func paragraph(
    _ spans: [ArticleSpan], heading: Bool = false, quote: Bool = false
  ) -> some View {
    if spans.contains(where: { $0.formula != nil }) {
      VStack(alignment: .leading, spacing: 1) {
        ForEach(Array(spans.enumerated()), id: \.offset) { _, s in
          if let formula = s.formula {
            ArticleFormulaView(formula: formula)
          } else if s.node != nil || s.lottery {
            ReplyRichText(
              nodes: [articleNode(s, heading: heading, quote: quote)], dynamicID: doc?.opus ?? "0")
          } else {
            rich([s]).textSelection(.enabled)
          }
        }
      }
    } else if spans.contains(where: { $0.node != nil || $0.lottery }) {
      ReplyRichText(
        nodes: spans.map { articleNode($0, heading: heading, quote: quote) },
        dynamicID: doc?.opus ?? "0",
        textStyle: heading ? .title2 : .body)
    } else if heading {
      rich(spans).piliFont(.title2, weight: .bold).textSelection(.enabled)
    } else if quote {
      rich(spans).italic().textSelection(.enabled)
    } else {
      rich(spans).textSelection(.enabled)
    }
  }
  private func articleNode(_ s: ArticleSpan, heading: Bool, quote: Bool) -> RichNode {
    var n = s.inline(heading: heading, quote: quote)
    if s.lottery, let op = doc?.opus, Int64(op) != nil,
      let u = URL(string: "https://www.bilibili.com/h5/lottery/result?business_id=" + op)
    {
      n.target = .url(u)
    }
    return n
  }
  @ViewBuilder private func content(_ b: ArticleBlock) -> some View {
    switch b {
    case .card(let c): resourceCard(c)
    case .paragraph(let a): paragraph(a)
    case .heading(let a): paragraph(a, heading: true)
    case .quote(let a):
      HStack {
        Rectangle().fill(.secondary).frame(width: 3)
        paragraph(a, quote: true)
      }.fixedSize(horizontal: false, vertical: true)
    case .code(let s):
      ScrollView(.horizontal) {
        Text(verbatim: s).font(.body.monospaced()).textSelection(.enabled).padding(8)
      }.background(.quaternary)
    case .divider: Divider()
    case .image(let u, let alt): articlePhoto(.init(u), alt)
    case .motion(let p, let alt): articlePhoto(p, alt)
    }
  }
  @ViewBuilder private func resourceCard(_ c: ArticleResource) -> some View {
    let label = HStack {
      if let u = c.cover {
        SiteThumbnail(url: u) {
          $0.resizable().scaledToFill()
        } placeholder: {
          Color.clear
        }.frame(width: 84, height: 58).clipped().cornerRadius(6)
      }
      VStack(alignment: .leading) {
        Text(c.title).font(.headline)
        if !c.detail.isEmpty { Text(c.detail).font(.caption).foregroundStyle(.secondary) }
      }
    }.frame(maxWidth: .infinity, alignment: .leading).padding(8).background(
      .quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    switch c.target {
    case .route(let r):
      NavigationLink {
        LinkDestination(item: r)
      } label: {
        label
      }
    case .vote(let id):
      NavigationLink {
        VoteView(id: id, dynamic: doc?.opus ?? "0")
      } label: {
        label
      }
    case .url(let url):
      NavigationLink {
        SitePage(url: url)
      } label: {
        label
      }
    default: label
    }
  }
  private func articlePhoto(_ p: GalleryPicture, _ alt: String) -> some View {
    GalleryLink(pictures, index: pictureIndices[p] ?? 0) {
      VStack {
        GalleryThumb(photo: p)
        if !alt.isEmpty { Text(alt).piliFont(.caption) }
      }
    }
  }
}
struct ArticleCollection: View {
  let id: Int64
  struct Payload: Decodable {
    struct Info: Decodable {
      let name, image_url: String?, words, read, articles_count: Int?, update_time: Int64?
    }
    struct Row: Decodable, Identifiable {
      struct Stats: Decodable { let view, like, reply: Int? }
      let id: Int64, title, summary: String?, image_urls: [String]?, dyn_id_str: String?,
        stats: Stats?
    }
    let list: Info?, author: Video.Owner?, articles: [Row]?
  }
  @State private var payload: Payload?
  @State private var issue: String?
  @State private var reload = 0
  var body: some View {
    List {
      if let p = payload {
        if let a = p.author, let mid = a.mid {
          NavigationLink(a.name ?? "作者空间") { CreatorSpace(mid: mid, name: a.name ?? "作者") }
        }
        if let info = p.list {
          if let u = info.image_url.flatMap(GalleryPicture.source) {
            GalleryLink([.init(u)], index: 0) {
              GalleryThumb(photo: .init(u)).frame(maxHeight: 160)
            }
          }
          if let n = info.read { LabeledContent("阅读", value: n.formatted()) }
          if let t = info.update_time {
            LabeledContent(
              "更新",
              value: Date(timeIntervalSince1970: Double(t)).formatted(
                date: .abbreviated, time: .omitted))
          }
          LabeledContent("文章", value: String(info.articles_count ?? p.articles?.count ?? 0))
          if let w = info.words { LabeledContent("总字数", value: String(w)) }
        }
        ForEach(p.articles ?? []) { row in
          NavigationLink {
            if let op = row.dyn_id_str, (Int64(op) ?? 0) > 0 {
              ArticleReader(opus: op)
            } else {
              ArticleReader(id: row.id)
            }
          } label: {
            VStack(alignment: .leading) {
              if let u = row.image_urls?.first.flatMap(GalleryPicture.source) {
                SiteThumbnail(url: u) {
                  $0.resizable().scaledToFill()
                } placeholder: {
                  Color.clear
                }.frame(height: 92).clipped()
              }
              Text(row.title ?? "专栏").piliFont(.headline)
              if let stats = row.stats {
                Text(
                  [
                    stats.view.map { "\($0) 阅读" }, stats.like.map { "\($0) 赞" },
                    stats.reply.map { "\($0) 评论" },
                  ].compactMap { $0 }.joined(separator: " · ")
                ).font(.caption2).foregroundStyle(.secondary)
              }
              if let s = row.summary { Text(s).lineLimit(2).piliFont(.caption) }
            }
          }
        }
      } else if let issue {
        PageFailure(message: issue) { reload += 1 }
      } else {
        PageLoading()
      }
    }.refreshable { reload += 1 }.navigationTitle(payload?.list?.name ?? "文集").toolbar {
      if let u = URL(string: "https://www.bilibili.com/read/mobile-readlist/rl" + String(id)) {
        NavigationLink {
          SitePage(url: u)
        } label: {
          Image(systemName: "safari").accessibilityLabel("浏览器打开")
        }
      }
    }.task(id: reload) {
      do {
        let p = try await BiliAPI.shared.read(
          "/x/article/list/web/articles", ["id": String(id), "web_location": "333.1400"],
          as: Payload.self)
        try Task.checkCancellation()
        payload = p
        issue = nil
      } catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
  }
}
