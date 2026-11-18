import SwiftUI

struct DanmakuList: View {
  let cid: Int64, aid: Int64?, duration: Double, current: Double, seek: (Double) -> Void
  let snapshot: (() -> [Bullet])?
  @State private var onScreen: Bool
  @EnvironmentObject private var accounts: AccountContext
  @State private var rows: [Bullet] = []
  @ObservedObject private var likes = BulletLikes.shared
  @ObservedObject private var recall = BulletRecall.shared
  @State private var selected: BulletPick?
  @State private var recalling: Bullet?
  @State private var note: String?
  @State private var liking: Int64?
  @ViewBuilder private func trailing(_ b: Bullet) -> some View {
    let uid = accounts.state.active
    let liked = uid.flatMap { u in b.entryID.map { likes.ids.contains(.init(uid: u, cid: cid, id: $0)) } } ?? false
    let n = likes.count(b, cid: cid, owner: uid)
    Button {
      guard let uid, let id = b.entryID, liking == nil else { note = "请先登录"; return }
      liking = id
      Task {
        defer { liking = nil }
        do {
          let receipt = try await BiliAPI.shared.bulletLike(id: id, cid: cid, on: !liked, uid: uid)
          guard accounts.state.active == uid else { return }
          likes.record(.init(uid: uid, cid: cid, id: id), receipt: receipt, initial: b.likes ?? 0)
          note = receipt.liked ? "点赞成功" : "取消点赞成功"
        } catch { note = error.localizedDescription }
      }
    } label: {
      Image(systemName: liked ? "hand.thumbsup.fill" : "hand.thumbsup")
        .foregroundStyle(liked ? Color.accentColor : Color.secondary)
        .frame(width: 34, height: 34)
        .overlay(alignment: .topTrailing) {
          if n > 0 { Text("\(n)").font(.system(size: 10.5)).foregroundStyle(.secondary).offset(x: 4, y: 1) }
        }
    }.buttonStyle(.plain).accessibilityLabel(liked ? "取消点赞" : "点赞")
    if let uid, recall.owns(b, cid: cid, author: uid) {
      Button { recalling = b } label: {
        Image(systemName: "arrow.uturn.backward").foregroundStyle(.secondary).frame(width: 34, height: 34)
      }.buttonStyle(.plain).accessibilityLabel("撤回")
    } else {
      Button {
        if uid == nil { note = "请先登录" } else { selected = BulletPick(bullet: b, rect: .zero, text: b.text) }
      } label: {
        Image(systemName: "exclamationmark.bubble").foregroundStyle(.secondary).frame(width: 34, height: 34)
      }.buttonStyle(.plain).accessibilityLabel("举报")
    }
  }
  @State private var page = 1
  @State private var search = ""
  @State private var retry = 0
  @State private var loading = true
  @State private var issue: String?
  @Environment(\.dismiss) private var dismiss
  init(
    cid: Int64, aid: Int64?, duration: Double, current: Double, seek: @escaping (Double) -> Void,
    snapshot: (() -> [Bullet])? = nil
  ) {
    self.snapshot = snapshot
    _onScreen = State(initialValue: snapshot != nil)
    self.cid = cid
    self.aid = aid
    self.duration = duration
    self.current = current
    self.seek = seek
    _page = State(initialValue: 1 + Int(max(0, current)) / 360)
  }
  private var pages: Int { max(page, max(1, Int(ceil(max(0, duration) / 360)))) }
  var body: some View {
    List {
      if snapshot != nil {
        ChipBar(items: [true, false], selection: $onScreen, title: { $0 ? "屏幕上" : "时间段" })
          .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
      }
      if !onScreen {
        Picker("时间段", selection: $page) {
          ForEach(1...pages, id: \.self) { n in
            Text(
              "\(clockText(Double(n-1)*360)) – \(clockText(duration>0 ? min(duration,Double(n)*360):Double(n)*360))"
            ).tag(n)
          }
        }
      }
      if loading {
        ProgressView()
      } else if let issue {
        Text(issue)
        Button("重试") { retry += 1 }
      } else {
        let matches = rows.filter {
          recall.visible($0, cid: cid)
            && (search.isEmpty || $0.text.localizedStandardContains(search))
        }
        if matches.isEmpty { Text("没有找到弹幕").foregroundStyle(.secondary) }
        // As the original's danmaku list: the text (tap to jump there), then 赞 with its count and
        // 撤回 for your own or 举报 at the trailing edge; long press copies.
        ForEach(Array(matches.enumerated()), id: \.offset) { _, b in
          HStack(spacing: 4) {
            Button {
              seek(b.time)
              dismiss()
            } label: {
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(clockText(b.time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(b.special?.text ?? b.text).font(.subheadline).foregroundStyle(.primary)
                  .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
              }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if b.entryID != nil { trailing(b) }
          }
          .contextMenu {
            Button("复制内容") { UIPasteboard.general.string = b.text }
            if let sender = b.sender, !sender.isEmpty {
              Button("屏蔽该发送者") {
                var s = DanmakuStyle.decode(
                  UserDefaults.standard.data(forKey: DanmakuStyle.key) ?? Data())
                let stored = Set(s.senders.split(whereSeparator: \.isNewline).map(String.init))
                s.senders = stored.union([sender]).sorted().joined(separator: "\n")
                do { try s.save() } catch { issue = error.localizedDescription }
              }
            }
          }
        }
      }
    }.piliSheet(item: $selected) { p in
      if let id = p.bullet.entryID, let uid = accounts.state.active {
        BulletReportSheet(cid: cid, id: id, uid: uid, sender: p.bullet.sender) { note = $0 }
      }
    }
    .confirmationDialog("撤回自己发送的这条弹幕？", isPresented: Binding(
      get: { recalling != nil }, set: { if !$0 { recalling = nil } }), presenting: recalling
    ) { b in
      Button("撤回", role: .destructive) {
        Task {
          guard let uid = accounts.state.active else { return }
          do { try await recall.recall(b, cid: cid, author: uid); note = "删除成功" }
          catch { note = error.localizedDescription }
        }
      }
    }
    .safeAreaInset(edge: .bottom) {
      if let note {
        Text(note).font(.caption).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 7)
          .background(.black.opacity(0.7), in: Capsule()).padding(.bottom, 8)
          .task(id: note) { try? await Task.sleep(for: .seconds(1.6)); if self.note == note { self.note = nil } }
      }
    }
    .navigationTitle("弹幕列表").searchable(text: $search, prompt: "搜索本段弹幕")
      .toolbar {
        Button {
          retry += 1
        } label: {
          Label("刷新弹幕", systemImage: "arrow.clockwise")
        }
      }
      .task(id: "\(cid):\(page):\(retry):\(onScreen):\(accounts.state.active ?? "")") {
        loading = true
        rows = []
        issue = nil
        do {
          let r =
            if onScreen { snapshot?() ?? [] } else {
              try await BiliAPI.shared.commentSegment(
                cid: cid, aid: aid, index: page, expectedAccount: accounts.state.active ?? "")
            }
          try Task.checkCancellation()
          rows = r
        } catch { if !Task.isCancelled { issue = error.localizedDescription } }
        if !Task.isCancelled { loading = false }
      }
  }
}
