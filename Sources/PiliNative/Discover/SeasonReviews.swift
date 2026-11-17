import SwiftUI

struct SeasonReviews: View {
  let media: Int64
  var publishing = true
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    let owner = accounts.state.active ?? ""
    ReviewList(media: media, owner: owner, publishing: publishing).id("\(media):\(owner)")
  }
}
private struct ReviewList: View {
  let media: Int64, owner: String
  var publishing = true
  @Environment(\.colorScheme) private var color
  @State private var long = true
  @State private var sort = 0
  @State private var revision = 0
  @State private var editor = false
  @State private var editing: SeasonReview?
  @State private var removing: SeasonReview?
  @State private var total: Int?
  @State private var loaded = Set<Int64>()
  @State private var busy = false
  @State private var issue: String?
  @State private var route: Route?
  private enum Route: Hashable { case creator(Int64, String), article(Int64), site(URL) }
  struct Response: Decodable { let list: [SeasonReview]?, next: String?, count: Int?, total: Int? }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        ChipBar(items: [true, false], selection: $long, title: { $0 ? "长评" : "短评" })
        Menu {
          Picker("顺序", selection: $sort) {
            Text("默认").tag(0)
            Text("最新").tag(1)
          }
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "arrow.up.arrow.down").font(.caption.weight(.semibold))
            Text(sort == 0 ? "默认" : "最新")
          }.font(.subheadline).foregroundStyle(.secondary)
        }.padding(.trailing, 16)
      }.padding(.vertical, 6)
      PageList(empty: "暂无点评", heading: total.map {
        AnyView(Text("共 \($0) 条").font(.caption).foregroundStyle(.secondary).listRowSeparator(.hidden))
      }) { cursor in
        var f = [
          "media_id": String(media), "ps": "20", "sort": String(sort), "web_location": "666.19",
        ]
        f["cursor"] = cursor
        let r = try await BiliAPI.shared.read(
          "/pgc/review/" + (long ? "long" : "short") + "/list", f, expectedAccount: owner,
          as: Response.self)
        try Task.checkCancellation()
        if cursor == nil { loaded = [] }
        total = long && sort == 1 ? nil : r.count ?? r.total
        let rows = (r.list ?? []).filter { $0.id > 0 && loaded.insert($0.id).inserted }
        let next = r.next.flatMap {
          !$0.isEmpty && $0 != cursor && $0 != "0" && (total.map { loaded.count < $0 } ?? true)
            ? $0 : nil
        }
        return Page(items: rows, next: next)
      } row: { r in
        review(r)
      }.id("\(long):\(sort):\(revision)")
    }.navigationTitle("点评")
    .navigationDestination(item: $route) { r in
      switch r {
      case .creator(let mid, let name): CreatorSpace(mid: mid, name: name)
      case .article(let id): ArticleReader(id: id)
      case .site(let url): SitePage(url: url)
      }
    }
    .onChange(of: long) { _, _ in total = nil }.onChange(of: sort) { _, _ in
      total = nil
    }.toolbar {
      if publishing {
        Menu {
          if !owner.isEmpty {
            Button("写短评") {
              editing = nil
              editor = true
            }
          }
          if let u = SeasonReviewPolicy.longEditor(media: media, dark: color == .dark) {
            Button("写长评") { route = .site(u) }
          }
        } label: {
          Image(systemName: "square.and.pencil").accessibilityLabel("写点评")
        }
      }
    }.piliSheet(isPresented: $editor) {
      ReviewEditor(media: media, owner: owner, review: editing) { revision += 1 }
    }
    .confirmationDialog(
      "删除短评和评分？",
      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
      presenting: removing
    ) { r in
      Button("删除", role: .destructive) { Task { await mutate("delete", r) } }
    }.alert("点评", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
      Button("好") {}
    } message: {
      Text(issue ?? "")
    }
  }
  /// The original client's review card: author with level and star rating, title and text,
  /// then date and actions. Every link pushes through `route`, so the row never grows chevrons.
  @ViewBuilder private func review(_ r: SeasonReview) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Button {
          if let mid = r.author?.mid, mid > 0 { route = .creator(mid, r.author?.uname ?? "用户空间") }
        } label: {
          HStack(spacing: 8) {
            SiteThumbnail(url: r.author?.avatar.flatMap(httpsURL)) { $0.resizable().scaledToFill() } placeholder: {
              Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.quaternary)
            }
            .frame(width: 32, height: 32).clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 4) {
                Text(r.author?.uname ?? "用户").font(.subheadline.weight(.medium)).lineLimit(1)
                if let level = r.author?.level { UserLevelBadge(level: level, height: 10) }
              }
              HStack(spacing: 1) {
                ForEach(0..<5, id: \.self) { i in
                  Image(systemName: i < r.stars ? "star.fill" : "star")
                    .font(.system(size: 10)).foregroundStyle(i < r.stars ? Color.orange : Color.secondary.opacity(0.4))
                }
              }.accessibilityElement().accessibilityLabel("\(r.stars) 星")
            }
          }
        }.buttonStyle(.plain)
        Spacer(minLength: 0)
        if let date = r.push_time_str { Text(date).font(.caption).foregroundStyle(.secondary) }
      }
      if let title = r.title, !title.isEmpty { Text(title).font(.headline) }
      if let body = r.content, !body.isEmpty {
        Text(body).font(.subheadline).lineLimit(long ? 4 : nil).textSelection(.enabled)
      }
      if long, let id = r.article_id, id > 0 {
        Button { route = .article(id) } label: {
          HStack(spacing: 2) {
            Text("阅读全文")
            Image(systemName: "chevron.right").font(.caption2.weight(.bold))
          }.font(.subheadline.weight(.medium))
        }.buttonStyle(.plain).foregroundStyle(.tint)
      }
      HStack(spacing: 16) {
        if !long, let n = r.review_id, n > 0, !owner.isEmpty {
          Button {
            Task { await mutate("like", r) }
          } label: {
            Label("\(r.stat?.likes ?? 0)",
              systemImage: r.stat?.liked == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
          }.accessibilityLabel(r.stat?.liked == 1 ? "取消赞同" : "赞同")
            .foregroundStyle(r.stat?.liked == 1 ? Color.accentColor : Color.secondary)
          Button {
            Task { await mutate("dislike", r) }
          } label: {
            Image(systemName: r.stat?.disliked == 1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
          }.accessibilityLabel(r.stat?.disliked == 1 ? "取消不赞同" : "不赞同")
            .foregroundStyle(r.stat?.disliked == 1 ? Color.accentColor : Color.secondary)
        } else if let n = r.stat?.likes {
          Label(String(n), systemImage: "hand.thumbsup").foregroundStyle(.secondary)
        }
        Spacer()
        if !long, let n = r.review_id, n > 0 {
          Menu {
            if owns(r) {
              if publishing {
                Button("编辑", systemImage: "pencil") { editing = r; editor = true }
              }
              Button("删除", systemImage: "trash", role: .destructive) { removing = r }
            }
            if let u = SeasonReviewPolicy.report(n, media: media) {
              Button("举报", systemImage: "exclamationmark.bubble") { route = .site(u) }
            }
          } label: {
            Image(systemName: "ellipsis").frame(width: 28, height: 24).contentShape(Rectangle())
          }.foregroundStyle(.secondary)
        }
      }
      .font(.caption).buttonStyle(.plain).disabled(busy)
    }
    .padding(.vertical, 6)
  }
  private func owns(_ r: SeasonReview) -> Bool {
    !owner.isEmpty && r.author?.mid.map(String.init) == owner
  }
  @MainActor private func mutate(_ action: String, _ review: SeasonReview) async {
    guard !busy, !owner.isEmpty, let id = review.review_id, id > 0, !long else { return }
    busy = true
    defer { busy = false }
    let path: String
    var fields = ["media_id": String(media), "review_id": String(id)]
    if action == "delete" {
      guard owns(review) else { return }
      path = "/pgc/review/short/del"
    } else {
      guard ["like", "dislike"].contains(action) else { return }
      path = "/pgc/review/action/" + action
      fields["review_type"] = "2"
    }
    do {
      try await BiliAPI.shared.submit(path, fields, expectedAccount: owner)
      revision += 1
    } catch { if !Task.isCancelled { issue = error.localizedDescription } }
  }
}
private struct ReviewEditor: View {
  let media: Int64, owner: String, review: SeasonReview?, saved: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var rating: Int
  @State private var text: String
  @State private var share = false
  @State private var busy = false
  @State private var issue: String?
  init(media: Int64, owner: String, review: SeasonReview?, saved: @escaping () -> Void) {
    self.media = media
    self.owner = owner
    self.review = review
    self.saved = saved
    _rating = State(initialValue: review?.stars ?? 0)
    _text = State(initialValue: review?.content ?? "")
  }
  var body: some View {
    PiliNavigationStack {
      Form {
        Picker("评分", selection: $rating) {
          if rating == 0 { Text("请选择").tag(0) }
          ForEach(1...5, id: \.self) { Text("\($0) 星").tag($0) }
        }
        TextEditor(text: $text).frame(minHeight: 100).accessibilityLabel("短评").onChange(of: text) {
          _, s in if s.count > 100 { text = String(s.prefix(100)) }
        }
        Text("\(text.count)/100").piliFont(.caption).foregroundStyle(.secondary)
        if review == nil { Toggle("同时分享到动态", isOn: $share) }
        if let issue { Text(issue) }
      }.disabled(busy).navigationTitle(review == nil ? "写短评" : "编辑短评").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
        ToolbarItem(placement: .confirmationAction) {
          Button(review == nil ? "发布" : "保存") { Task { await send() } }.disabled(
            busy || rating == 0)
        }
      }
    }.interactiveDismissDisabled(busy)
  }
  @MainActor private func send() async {
    guard !busy,
      let f = SeasonReviewPolicy.post(
        media: media, stars: rating, body: text, share: share, editing: review, owner: owner)
    else { return }
    busy = true
    defer { busy = false }
    do {
      try await BiliAPI.shared.submit(
        review == nil ? "/pgc/review/short/post" : "/pgc/review/short/modify", f,
        expectedAccount: owner)
      saved()
      dismiss()
    } catch { if !Task.isCancelled { issue = error.localizedDescription } }
  }
}
