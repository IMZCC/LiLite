import PiliWire

import SwiftUI

struct Conversation: Decodable, Identifiable {
  struct AccountInfo: Decodable { let name: String?, pic_url: String? }
  let talker_id: Int64, session_type: Int, unread_count: Int?
  let last_msg: DirectMessage?
  var top_ts: Int64? = nil
  var is_dnd: Int? = nil
  var serviceRecipient: Int64? = nil
  var session_ts: Int64? = nil
  var system_msg_type: Int? = nil
  var account_info: AccountInfo? = nil
  var group_name: String? = nil, group_cover: String? = nil
  // System talker IDs are not member UIDs; their identity belongs to the session.
  var profile: BiliAPI.IMOther? {
    let name = session_type == 2 ? group_name : account_info?.name
    let face = session_type == 2 ? group_cover : account_info?.pic_url
    guard name?.isEmpty == false || face?.isEmpty == false else { return nil }
    return .init(mid: talker_id, name: name?.isEmpty == false ? name : nil,
                 face: face?.isEmpty == false ? face : nil, sign: nil)
  }
  var needsUserProfile: Bool {
    session_type == 1 && (system_msg_type ?? 0) == 0 && profile == nil
  }
  var receiver: Int64? {
    let target = serviceRecipient ?? talker_id
    return session_type == 1 && target > 0 ? target : nil
  }
  var id: String { "\(session_type):\(talker_id)" }
}
struct DirectMessage: Decodable, Identifiable {
  let contentCache = IMMessageContentCache()
  private enum CodingKeys: String, CodingKey {
    case msg_key, msg_seqno, sender_uid, content, msg_type, timestamp, msg_status, msg_source
  }
  let msg_key: MessageKey?
  let msg_seqno: Int64?
  let sender_uid: Int64?
  let content: String?
  let msg_type: Int?
  let timestamp: Int64?
  var msg_status: Int? = nil, msg_source: Int? = nil
  var id: String {
    if let n = msg_seqno, n > 0 { return "s:" + String(n) }
    if let k = IMHistoryPolicy.key(msg_key?.value) { return "k:" + k }
    return "f:" + String(sender_uid ?? 0) + ":" + String(timestamp ?? 0) + ":"
      + String(content?.hashValue ?? 0)
  }
  var payload: [String: Any] {
    contentCache.payload(content)
  }
  var card: IMCardBody { contentCache.card(for: self) }
  var text: String {
    if msg_type == 5 || msg_status == 1 { return "已撤回一条消息" }
    let p = payload
    return (p["content"] as? String) ?? (p["title"] as? String) ?? (p["text"] as? String)
      ?? (msg_type == 2 ? "图片" : "消息")
  }
  var image: URL? {
    guard msg_type == 2 || msg_type == 6, let s = payload["url"] as? String else { return nil }
    return httpsURL(s)
  }
}
extension BiliAPI {
  func conversations(cursor: String?, owner: String) async throws -> Page<Conversation> {
    struct R: Decodable {
      let session_list: [Conversation]?
      let has_more: Int?
    }
    var q = [
      "session_type": "1", "group_fold": "1", "unfollow_fold": "0", "sort_rule": "2", "build": "0",
      "mobi_app": "web",
    ]
    q["end_ts"] = cursor
    let r = try await read(
      "/session_svr/v1/session_svr/get_sessions", try await sign(q), host: "api.vc.bilibili.com",
      expectedAccount: owner, as: R.self)
    return Page(
      items: r.session_list ?? [],
      next: r.has_more == 1 ? r.session_list?.last?.session_ts.map(String.init) : nil)
  }
  struct MessageHistoryPage {
    let items: [DirectMessage], next: String?, emotes: [String: RichNode.Emote],
      revoked: Set<String>, acknowledge: Int64?
    init(
      messages: [DirectMessage], before: Int64?, hasMore: Bool, minSeq: Int64?,
      emotes: [String: RichNode.Emote]
    ) {
      self.emotes = emotes
      let seqs = messages.compactMap(\.msg_seqno)
      next = IMHistoryPolicy.older(flag: hasMore, minimum: minSeq, sequences: seqs, before: before)
      revoked = Set(
        messages.compactMap { m in
          m.msg_type == 5
            ? IMHistoryPolicy.recall(m.content)
            : (m.msg_status == 1 ? IMHistoryPolicy.key(m.msg_key?.value) : nil)
        })
      items = messages.filter { $0.msg_type != 5 }
      acknowledge =
        before != nil
          || (messages.count == 1 && messages[0].msg_type == 18 && messages[0].msg_source == 18)
        ? nil : seqs.filter { $0 > 0 }.max()
    }
  }
  func messages(_ c: Conversation, cursor: String?, uid: String) async throws -> MessageHistoryPage
  {
    guard let identity = try await AccountJar.shared.current(credentials:.mobile), identity.id == uid else {
      throw ServiceError("账号已切换")
    }
    let before = cursor.flatMap(Int64.init)
    if cursor != nil && (before ?? 0) <= 0 { throw ServiceError("消息页码无效") }
    var dictionary = [String: RichNode.Emote]()
    func add(_ text: String?, _ raw: String?, _ gif: String?, _ size: Int?) {
      guard let text, !text.isEmpty, dictionary[text] == nil,
        let u = raw.flatMap(GalleryPicture.source) ?? gif.flatMap(GalleryPicture.source)
      else { return }
      dictionary[text] = .init(
        name: text, url: u, size: size ?? 1, jump: nil, jumpTitle: nil,
        animation: gif.flatMap(GalleryPicture.source))
    }
    if c.session_type == 1, identity.mobileToken?.isEmpty == false {
      let r = try await instantMessaging(for: uid).history(talker: c.talker_id, before: before)
      for e in r.eInfos { add(e.text, e.url, e.gifURL, Int(e.size)) }
      let list = r.messages.map { m in
        DirectMessage(
          msg_key: m.msgKey == 0 ? nil : MessageKey(String(m.msgKey)), msg_seqno: m.msgSeqno,
          sender_uid: m.senderUid, content: m.content, msg_type: Int(m.msgType),
          timestamp: m.timestamp, msg_status: Int(m.msgStatus), msg_source: Int(m.msgSource))
      }
      return .init(
        messages: list, before: before, hasMore: r.hasMore_p == 1, minSeq: r.minSeqno,
        emotes: dictionary)
    }
    struct R: Decodable {
      struct Face: Decodable { let text: String?, url: String?, gif_url: String?, size: Int? }
      let messages: [DirectMessage]?, has_more: Int?, min_seqno: Int64?, e_infos: [Face]?
    }
    var q = [
      "talker_id": String(c.talker_id), "session_type": String(c.session_type), "size": "20",
      "sender_device_id": "1", "build": "0", "mobi_app": "web",
    ]
    q["end_seqno"] = cursor
    let r = try await read(
      "/svr_sync/v1/svr_sync/fetch_session_msgs", try await sign(q), host: "api.vc.bilibili.com",
      expectedAccount: uid, as: R.self)
    for e in r.e_infos ?? [] { add(e.text, e.url, e.gif_url, e.size) }
    return .init(
      messages: r.messages ?? [], before: before, hasMore: r.has_more == 1, minSeq: r.min_seqno,
      emotes: dictionary)
  }
}
struct Inbox: View {
  @EnvironmentObject var accounts: AccountContext
  @Environment(\.scenePhase) private var scene
  @Environment(\.colorScheme) private var color
  @AppStorage("inbox.hideLikes") private var hideLikes = false
  @State private var counts: [String: Int64] = [:]
  @State private var notice: NoticeKind?
  @State private var fans = false
  @State private var visible = false
  @State private var countRevision = 0
  private struct CountRequest: Equatable {
    let owner: String?
    let mobile: Bool
    let active: Bool
    let revision: Int
  }
  private var owner: Identity? { accounts.state.accounts.first { $0.id == accounts.state.active } }
  private func key(_ k: NoticeKind) -> String {
    switch k {
    case .at: "at"
    case .reply: "reply"
    case .like: "like"
    case .system: "sys_msg"
    }
  }
  private var header: AnyView {
    AnyView(
      NoticeShortcuts(
        kinds: NoticeKind.allCases.filter { !hideLikes || $0 != .like },
        count: { counts[key($0)] ?? 0 }, open: { notice = $0 }
      )
      .listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 14, trailing: 8)))
  }
  private var fansURL: URL? {
    URL(
      string: "https://www.bilibili.com/h5/follow/newFans?navhide=1&native.theme="
        + (color == .dark ? "2&night=1" : "1&night=0"))
  }
  var body: some View {
    Group {
      if let owner {
        if owner.mobileToken != nil {
          IMSessions(uid: owner.id, title: "消息", heading: header, refreshed: { await refreshCounts() })
        } else {
          WebSessions(uid: owner.id, title: "消息", heading: header, refreshed: { await refreshCounts() })
        }
      } else {
        ContentUnavailableView {
          Label("登录后查看消息", systemImage: "bubble.left.and.bubble.right")
        } description: {
          Text("回复、@、点赞和私信都会出现在这里")
        }
      }
    }
    .navigationTitle("消息")
    .navigationDestination(item: $notice) { NoticeFeed(kind: $0) }
    .navigationDestination(isPresented: $fans) { if let fansURL { SitePage(url: fansURL) } }
    .toolbar {
      if let owner {
        ToolbarItem(placement: .topBarTrailing) {
          Button { fans = true } label: {
            Image(systemName: "person.badge.plus").accessibilityLabel("新增粉丝")
          }
        }
        if owner.mobileToken == nil {
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              NavigationLink("移动端授权") { MobileAuthorization(uid: owner.id) }
              NavigationLink("通讯录") { IMContactBook(uid: owner.id) }
            } label: {
              Image(systemName: "ellipsis").accessibilityLabel("消息操作")
            }
          }
        }
      }
    }
    .onAppear { visible = true }
    .onDisappear {
      visible = false
      NotificationCenter.default.post(name: .piliUnreadChanged, object: nil)
    }.task(id: CountRequest(owner: owner?.id, mobile: owner?.mobileToken != nil,
      active: visible && scene == .active, revision: countRevision)) {
      guard visible, scene == .active else { return }
      await refreshCounts()
    }.onReceive(NotificationCenter.default.publisher(for: .piliUnreadChanged)) { _ in
      if visible && scene == .active { countRevision &+= 1 }
    }
  }
  @MainActor private func refreshCounts() async {
    guard let owner else {
      counts = [:]
      return
    }
    let id = owner.id
    do {
      let result: [String: Int64]
      if owner.mobileToken?.isEmpty == false {
        result = try await BiliAPI.shared.instantMessaging(for: id).noticeCounts()
      } else {
        result = try await BiliAPI.shared.read(
          "/x/msgfeed/unread", ["build": "0", "mobi_app": "web"], expectedAccount: id,
          as: IMUnreadFields.self
        ).values
      }
      try Task.checkCancellation()
      if self.owner?.id == id { withAnimation(.easeOut(duration: 0.2)) { counts = result } }
    } catch { if !Task.isCancelled && self.owner?.id == id { counts = [:] } }
  }
}

/// The four notice entries across the top of the message center, as in the original client.
private struct NoticeShortcuts: View {
  let kinds: [NoticeKind]
  let count: (NoticeKind) -> Int64
  let open: (NoticeKind) -> Void
  var body: some View {
    HStack(spacing: 0) {
      ForEach(kinds, id: \.self) { k in
        Button { open(k) } label: { tile(k) }
          .buttonStyle(.plain).frame(maxWidth: .infinity)
      }
    }
  }
  private func tile(_ k: NoticeKind) -> some View {
    let n = max(0, count(k))
    return VStack(spacing: 7) {
      Image(systemName: icon(k)).font(.title3.weight(.semibold)).foregroundStyle(tint(k))
        .frame(width: 52, height: 52)
        .background(tint(k).opacity(0.14), in: Circle())
        .overlay(alignment: .topTrailing) {
          if n > 0 {
            Text(n > 99 ? "99+" : String(n)).font(.caption2.weight(.semibold)).monospacedDigit()
              .foregroundStyle(.white).padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
              .background(.red, in: Capsule()).offset(x: 6, y: -3)
              .transition(.scale.combined(with: .opacity))
          }
        }
      Text(k.rawValue).font(.caption).foregroundStyle(.primary)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityValue(n > 0 ? "\(n) 条未读" : "")
  }
  private func icon(_ k: NoticeKind) -> String {
    switch k {
    case .reply: "bubble.left.and.text.bubble.right.fill"
    case .at: "at"
    case .like: "hand.thumbsup.fill"
    case .system: "bell.fill"
    }
  }
  private func tint(_ k: NoticeKind) -> Color {
    switch k {
    case .reply: .blue
    case .at: .teal
    case .like: .pink
    case .system: .orange
    }
  }
}

/// A list row that navigates without the disclosure chevron a bare `NavigationLink` draws.
/// Inside a `List` (see `inListRows`) the row cell carries an invisible link, so no chevron is
/// drawn and the label keeps the full width; elsewhere it is an ordinary plain-style link.
struct PlainRowLink<Destination: View, Label: View>: View {
  @ViewBuilder let destination: () -> Destination
  @ViewBuilder let label: () -> Label
  @Environment(\.inListRows) private var inList
  var body: some View {
    if inList {
      ZStack {
        NavigationLink(destination: destination) { EmptyView() }.opacity(0)
        label()
      }
    } else {
      // Cards in grids and feeds: highlight under an iPad / Duo trackpad pointer.
      NavigationLink(destination: destination, label: label).buttonStyle(.plain)
        .contentShape(.hoverEffect, .rect(cornerRadius: 12)).hoverEffect(.highlight)
    }
  }
}
private struct InListRowsKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
  /// Set on `List`s so `PlainRowLink` rows hide the disclosure chevron.
  var inListRows: Bool {
    get { self[InListRowsKey.self] }
    set { self[InListRowsKey.self] = newValue }
  }
}

/// Conversation row shared by the app and web session lists.
struct SessionRowLabel: View {
  let photo: URL?
  let name: String
  var tag: String? = nil
  let summary: String
  var date: Date? = nil
  var unread: String? = nil
  var dot = false
  var live = false
  var pinned = false
  var muted = false
  var body: some View {
    HStack(spacing: 12) {
      ZStack {
        Circle().fill(.quaternary)
        if let photo {
          SiteThumbnail(url: photo) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
        } else {
          Image(systemName: "person.fill").foregroundStyle(.secondary)
        }
      }
      .frame(width: 48, height: 48).clipShape(Circle())
      .overlay(alignment: .bottom) {
        if live {
          Text("直播").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.pink, in: Capsule()).offset(y: 4)
            .accessibilityLabel("直播中")
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 5) {
          Text(name).font(.body.weight(.medium)).lineLimit(1)
          if let tag, !tag.isEmpty {
            Text(tag).font(.caption2.weight(.medium)).foregroundStyle(.tint)
              .padding(.horizontal, 5).padding(.vertical, 1)
              .background(Color.accentColor.opacity(0.12), in: Capsule())
          }
          if pinned {
            Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
              .accessibilityLabel("已置顶")
          }
          Spacer(minLength: 4)
          if let date {
            Text(Self.stamp(date)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
          }
        }
        HStack(spacing: 6) {
          Text(summary.isEmpty ? " " : summary).font(.subheadline).foregroundStyle(.secondary)
            .lineLimit(1)
          Spacer(minLength: 4)
          if muted {
            Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.tertiary)
              .accessibilityLabel("免打扰")
          }
          if let unread {
            Text(unread).font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
              .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 18)
              .background(muted ? Color.secondary : Color.red, in: Capsule())
          } else if dot {
            Circle().fill(muted ? Color.secondary : Color.red).frame(width: 8, height: 8)
              .accessibilityLabel("有未读消息")
          }
        }
      }
    }
    .padding(.vertical, 6).contentShape(Rectangle())
  }
  static func stamp(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
    if cal.isDateInYesterday(d) { return "昨天" }
    if cal.isDate(d, equalTo: .now, toGranularity: .year) {
      return d.formatted(.dateTime.month(.defaultDigits).day())
    }
    return d.formatted(.dateTime.year().month(.defaultDigits).day())
  }
}
struct WebSessions: View {
  let uid: String
  var title = "私信"
  var heading: AnyView? = nil
  var refreshed: (() async -> Void)? = nil
  @State private var dirty = false
  @State private var profiles: [String: BiliAPI.IMOther] = [:]
  @State private var removal: Conversation?
  @State private var revision = 0
  @State private var issue: String?
  var body: some View {
    // Read the state here (not only inside the row closure, which runs in PageList's body) so
    // this view re-renders and hands PageList fresh rows once the profiles arrive.
    let known = profiles
    PageList(empty: "暂无会话", heading: heading, refreshed: refreshed) {
      let page = try await BiliAPI.shared.conversations(cursor: $0, owner: uid)
      try Task.checkCancellation()
      for c in page.items {
        if let profile = c.profile { profiles[c.id] = profile }
      }
      let missing = page.items.filter { $0.needsUserProfile && profiles[$0.id] == nil }
      if !missing.isEmpty {
        do {
          let people = try await BiliAPI.shared.imPeople(missing.map(\.talker_id), owner: uid)
          try Task.checkCancellation()
          for c in missing {
            if let person = people.first(where: { $0.mid == c.talker_id }) { profiles[c.id] = person }
          }
        } catch {
          try Task.checkCancellation()
          await DiagnosticJournal.shared.add("消息", "会话资料加载失败 · \(error.localizedDescription)")
        }
      }
      return page
    } row: { c in
      let person = c.profile ?? known[c.id]
      PlainRowLink {
        ChatHistory(conversation: c, name: person?.name, originUID: uid)
      } label: {
        let n = c.unread_count ?? 0
        SessionRowLabel(
          photo: person?.face.flatMap(httpsURL),
          name: person?.name ?? "UID " + String(c.talker_id),
          summary: c.last_msg?.text ?? "",
          date: c.last_msg?.timestamp.flatMap { $0 > 0 ? Date(timeIntervalSince1970: Double($0)) : nil },
          unread: n > 0 ? (n > 99 ? "99+" : String(n)) : nil,
          pinned: (c.top_ts ?? 0) > 0, muted: (c.is_dnd ?? 0) == 1)
      }
      .swipeActions {
        if c.session_type == 1 {
          Button("删除", role: .destructive) { removal = c }
          Button((c.top_ts ?? 0) > 0 ? "取消置顶" : "置顶") { Task { await update(c, .pin) } }
        }
      }
      .contextMenu {
        if c.session_type == 1 {
          if (c.unread_count ?? 0) > 0 { Button("标为已读") { Task { await mark(c) } } }
          ContextLink("聊天设置", systemImage: "gearshape") {
            IMConversationSettings(conversation: c, uid: uid, name: person?.name)
          }
          Button((c.is_dnd ?? 0) == 1 ? "开启提醒" : "免打扰") { Task { await update(c, .mute) } }
        }
      }
    }.id(revision).contextPushHost().navigationTitle(title)
      .onReceive(NotificationCenter.default.publisher(for: .piliIMChanged)) { n in
        if n.object as? String == uid { dirty = true }
      }
      .onAppear {
        if dirty {
          dirty = false
          revision += 1
        }
      }
      .confirmationDialog(
        "删除此会话？",
        isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
        presenting: removal
      ) { c in Button("删除", role: .destructive) { Task { await update(c, .delete) } } }
      .alert("私信", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
        Button("好") {}
      } message: {
        Text(issue ?? "")
      }
  }
  @MainActor private func mark(_ c: Conversation) async {
    do {
      let page = try await BiliAPI.shared.messages(c, cursor: nil, uid: uid)
      guard let seq = page.acknowledge else { throw ServiceError("没有可标记的消息") }
      try await BiliAPI.shared.acknowledge(c, seq, expectedUser: uid)
      revision += 1
    } catch { issue = error.localizedDescription }
  }
  @MainActor private func update(_ c: Conversation, _ action: BiliAPI.IMMutation) async {
    do {
      try await BiliAPI.shared.modifySession(c, action, user: uid)
      revision += 1
    } catch { issue = error.localizedDescription }
  }
}
extension BiliAPI {
  enum IMMutation { case pin, mute, delete }
  func modifySession(_ c: Conversation, _ action: IMMutation, user uid: String) async throws {
    guard c.session_type == 1, c.talker_id > 0, let account = try await AccountJar.shared.current(),
      account.id == uid, let csrf = account.csrf
    else { throw ServiceError("请重新登录") }
    let path: String
    var fields = [
      "talker_id": String(c.talker_id), "session_type": "1", "csrf": csrf, "csrf_token": csrf,
      "build": "0", "mobi_app": "web",
    ]
    switch action {
    case .mute:
      path = "/link_setting/v1/link_setting/set_msg_dnd"
      fields = ["uid": uid, "dnd_uid": String(c.talker_id), "setting": c.is_dnd == 1 ? "0" : "1"]
    case .delete, .pin:
      path = "/session_svr/v1/session_svr/" + (action == .pin ? "set_top" : "remove_session")
      if action == .pin { fields["op_type"] = (c.top_ts ?? 0) > 0 ? "0" : "1" }
      fields = try await sign(fields)
    }
    _ = try await messageForm(path, fields: fields, query: [:], account: account)
  }
}
struct ChatHistory: View {
  let conversation: Conversation
  var name: String? = nil, originUID: String? = nil
  var live = false
  @State private var opened: String?
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    Group {
      if let owner = originUID ?? opened {
        if accounts.state.active == owner {
          ChatThread(conversation: conversation, name: name, live: live, uid: owner).id(
            owner + ":" + conversation.id)
        } else {
          ContentUnavailableView("账号已切换", systemImage: "person.crop.circle")
        }
      } else if accounts.state.active == nil {
        ContentUnavailableView("请先登录", systemImage: "person.crop.circle")
      } else {
        ProgressView()
      }
    }.onAppear { if opened == nil { opened = accounts.state.active } }
  }
}
private struct ChatThread: View {
  @State private var emotes = [String: RichNode.Emote]()
  @State private var revoked = Set<String>()
  let conversation: Conversation
  var name: String? = nil
  var live = false
  let uid: String
  @EnvironmentObject var accounts: AccountContext
  @State private var revision = 0
  @State private var lastAck: Int64 = 0
  @State private var report: DirectMessage?
  @State private var retract: DirectMessage?
  @State private var forward: DirectMessage?
  @State private var issue: String?
  var body: some View {
    ConversationTimeline(revision: revision) { cursor in
      guard uid == accounts.state.active else { throw ServiceError("账号已切换") }
      let page = try await BiliAPI.shared.messages(conversation, cursor: cursor, uid: uid)
      try Task.checkCancellation()
      guard uid == accounts.state.active else { throw ServiceError("账号已切换") }
      emotes.merge(page.emotes) { _, new in new }
      revoked.formUnion(page.revoked)
      if let seq = page.acknowledge, seq > lastAck {
        do {
          try await BiliAPI.shared.acknowledge(conversation, seq, expectedUser: uid)
          lastAck = max(seq, lastAck)
        } catch {
          if !Task.isCancelled && accounts.state.active == uid {
            issue = error.localizedDescription
          }
        }
      }
      return Page(items: page.items, next: page.next)
    } row: { m in
      let mine = m.sender_uid.map(String.init) == uid
      VStack(alignment: .leading, spacing: 5) {
        Group {
          if let author = m.sender_uid, author > 0 {
            NavigationLink {
              CreatorSpace(mid: author, name: mine ? "我的空间" : name ?? "用户空间")
            } label: {
              Text(
                mine ? "我" : conversation.session_type == 1 ? name ?? "对方" : "UID " + String(author)
              )
            }.buttonStyle(.borderless)
          } else {
            Text(
              m.sender_uid.map(String.init) == accounts.state.active && m.sender_uid != nil
                ? "我"
                : (conversation.session_type == 1
                  ? (name ?? "对方") : (m.sender_uid.map { "UID " + String($0) } ?? "群成员"))
            )
          }
        }.piliFont(.caption).foregroundStyle(.secondary)
        if m.msg_status == 1 || IMHistoryPolicy.key(m.msg_key?.value).map(revoked.contains) == true
        {
          Text("消息已撤回").font(.caption).foregroundStyle(.secondary)
        } else if let url = m.image {
          GalleryLink([.init(url)], index: 0) {
            SiteThumbnail(url: url) {
              $0.resizable().scaledToFit()
            } placeholder: {
              ProgressView()
            }.frame(maxHeight: 200)
          }
        } else if let card = IMShareCard.incoming(m.msg_type, m.payload) {
          if let route = card.route {
            NavigationLink {
              LinkDestination(item: route)
            } label: {
              IMCardPreview(card: card)
            }
          } else {
            NavigationLink {
              DynamicDetail(id: card.resource, byAlbum: true)
            } label: {
              IMCardPreview(card: card)
            }
          }
        } else if m.msg_type == 1 {
          ReplyRichText(nodes: IMHistoryPolicy.tokenize(m.text, emotes: emotes))
        } else {
          IMContentView(message: m)
        }
        if let t = m.timestamp {
          Text(
            Date(timeIntervalSince1970: Double(t)), format: .dateTime.month().day().hour().minute()
          ).piliFont(.caption2)
        }
      }.padding(9).background(
        mine ? Color.accentColor.opacity(0.12) : Color(uiColor: .secondarySystemBackground),
        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
      )
      .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading).contextMenu {
        if m.msg_status != 1, IMHistoryPolicy.key(m.msg_key?.value).map(revoked.contains) != true {
          if IMForwardContent.read(type: m.msg_type, fields: m.payload) != nil,
            IMHistoryPolicy.key(m.msg_key?.value) != nil, (m.msg_seqno ?? 0) > 0
          {
            Button("转发给联系人") { forward = m }
          }
          if m.msg_type == 1, !m.text.isEmpty {
            Button("复制文字") { UIPasteboard.general.string = m.text }
          }
        }
        if !mine, cReportable(m) { Button("举报消息", role: .destructive) { report = m } }
        if conversation.receiver != nil, let uid = m.sender_uid,
          String(uid) == accounts.state.active, m.msg_key != nil,
          m.msg_type != 5, m.msg_status != 1,
          IMHistoryPolicy.key(m.msg_key?.value).map(revoked.contains) != true
        {
          Button("撤回", role: .destructive) { retract = m }
        }
      }
    }.piliSheet(item: $forward) { m in
      if let payload = IMForwardContent.read(type: m.msg_type, fields: m.payload) {
        PiliNavigationStack {
          IMShareSheet(content: payload, uid: uid) {
            guard accounts.state.active == uid, let seq = m.msg_seqno, seq > 0, seq < Int64.max,
              let k = IMHistoryPolicy.key(m.msg_key?.value), !revoked.contains(k)
            else { throw ServiceError("消息已变更") }
            let p = try await BiliAPI.shared.messages(
              conversation, cursor: String(seq + 1), uid: uid)
            guard !p.revoked.contains(k),
              let original = p.items.first(where: {
                IMHistoryPolicy.key($0.msg_key?.value) == k && $0.msg_seqno == seq
                  && $0.sender_uid == m.sender_uid && $0.msg_type == m.msg_type
                  && $0.msg_status != 1
              }),
              let live = IMForwardContent.read(type: original.msg_type, fields: original.payload)
            else { throw ServiceError("原消息已撤回或无法核实") }
            return live
          }
        }
      }
    }.piliSheet(item: $report) { m in
      if let sender = m.sender_uid, let key = m.msg_key?.value {
        PiliNavigationStack { IMMessageReport(uid: uid, sender: sender, key: key) }
      }
    }
    .navigationTitle(name ?? "私信").toolbar {
      if conversation.session_type == 1 {
        if let mid = conversation.receiver {
          ToolbarItem(placement: .principal) {
            NavigationLink {
              CreatorSpace(mid: mid, name: name ?? "用户空间")
            } label: {
              Text((name ?? "私信") + (live ? " · 直播中" : ""))
            }.piliTapFeedback()
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          NavigationLink {
            IMConversationSettings(conversation: conversation, uid: uid, name: name)
          } label: {
            Image(systemName: "gearshape").accessibilityLabel("聊天设置")
          }
        }
      }
    }.safeAreaInset(edge: .bottom) {
      if let receiver = conversation.receiver {
        MessageComposer(target: receiver, uid: uid) {
          NotificationCenter.default.post(name: .piliIMChanged, object: uid)
          revision += 1
        }
      }
    }
    .confirmationDialog(
      "撤回这条消息？", isPresented: Binding(get: { retract != nil }, set: { if !$0 { retract = nil } }),
      presenting: retract
    ) { m in
      Button("撤回", role: .destructive) {
        Task {
          do {
            if let receiver = conversation.receiver, let key = m.msg_key?.value,
              let sender = m.sender_uid.map(String.init),
              sender == accounts.state.active
            {
              try await BiliAPI.shared.sendDirect(
                to: receiver, text: nil, image: nil, withdraw: key,
                expectedUser: sender)
              if let id = IMHistoryPolicy.key(key) { revoked.insert(id) }
              NotificationCenter.default.post(name: .piliIMChanged, object: uid)
              revision += 1
            }
          } catch { issue = error.localizedDescription }
        }
      }
    }
    .alert("私信", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
      Button("好") {}
    } message: {
      Text(issue ?? "")
    }
  }
  private func cReportable(_ m: DirectMessage) -> Bool {
    conversation.session_type == 1 && m.sender_uid == conversation.talker_id && m.msg_status != 1
      && m.msg_type != 5
      && IMHistoryPolicy.key(m.msg_key?.value).map { !revoked.contains($0) } == true
  }
}
