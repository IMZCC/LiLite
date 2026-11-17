import PiliWire

import SwiftUI

struct IMContactBook: View {
  let uid: String
  var choose: ((Creator) -> Void)? = nil
  @State private var fans = false
  @State private var text = ""
  @State private var term = ""
  @State private var revision = 0
  @State private var remove: Creator?
  @State private var error: String?
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(spacing: 0) {
      ChipBar(items: [false, true], selection: $fans, title: { $0 ? "我的粉丝" : "我的关注" })
        .padding(.vertical, 6)
      PageList(empty: "没有找到联系人") { c in
        try await BiliAPI.shared.connections(
          uid: uid, fans: fans, page: Int(c ?? "1") ?? 1, term: fans ? "" : term,
          expectedAccount: uid)
      } row: { person in
        if let choose {
          Button(person.uname ?? String(person.mid)) {
            choose(person)
            dismiss()
          }
        } else {
          PlainRowLink {
            CreatorSpace(mid: person.mid, name: person.uname ?? "用户空间")
          } label: {
            Text(person.uname ?? String(person.mid))
          }
          .contextMenu {
            ContextLink("发私信", systemImage: "envelope") {
              ChatHistory(
                conversation: .init(
                  talker_id: person.mid, session_type: 1, unread_count: nil, last_msg: nil),
                name: person.uname, originUID: uid)
            }
            if fans && accounts.state.active == uid {
              Button("移除粉丝", role: .destructive) { remove = person }
            }
          }
        }
      }.id("\(uid):\(fans):\(term):\(revision)")
    }.contextPushHost().navigationTitle("通讯录").confirmationDialog(
      "移除这位粉丝？", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } }),
      presenting: remove
    ) { p in
      Button("移除", role: .destructive) {
        Task {
          do {
            guard fans && accounts.state.active == uid else { return }
            try await BiliAPI.shared.submit(
              "/x/relation/modify", ["fid": String(p.mid), "act": "7", "re_src": "11"],
              expectedAccount: uid)
            revision += 1
          } catch { self.error = error.localizedDescription }
        }
      }
    }.alert("通讯录", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("好") {}
    } message: {
      Text(error ?? "")
    }.searchable(text: $text, prompt: "搜索关注的人")
      .onSubmit(of: .search) {
        fans = false
        term = text.trimmingCharacters(in: .whitespacesAndNewlines)
      }.onChange(of: text) { _, v in if v.isEmpty { term = "" } }
  }
}
struct IMSessions: View {
  struct Row: Identifiable {
    let record: PiliIM_Session
    var id: String {
      switch record.id.id {
      case .privateID(let n): return "p:\(n.talkerUid)"
      case .groupID(let n): return "g:\(n.groupID)"
      case .foldID(let n): return "f:\(n.type.rawValue)"
      case .systemID(let n): return "s:\(n.type.rawValue)"
      case .customerID(let n): return "c:\(n.shopType):\(n.shopID)"
      case nil: return "n:\(record.sequenceNumber):\(record.sessionInfo.sessionName)"
      }
    }
    var name: String {
      let value = record.sessionInfo.sessionName
      return value.isEmpty ? "会话" : value
    }
    var photo: URL? {
      guard let res = record.sessionInfo.avatar.fallbackLayers.layers.first?.resource else {
        return nil
      }
      return [
        res.resImage.imageSrc.remote.url, res.resAnimation.webpSrc.remote.url,
        res.resNativeDraw.drawSrc.remote.url,
      ].compactMap(httpsURL).first
    }
    var conversation: Conversation? {
      let id: Int64
      let type: Int
      switch record.id.id {
      case .privateID(let p):
        id = p.talkerUid
        type = 1
      case .groupID(let g):
        id = g.groupID
        type = 2
      default: return nil
      }
      return .init(
        talker_id: id, session_type: type, unread_count: Int(exactly: record.unread.number),
        last_msg: nil, top_ts: record.isPinned ? 1 : 0, is_dnd: record.isMuted ? 1 : 0,
        serviceRecipient: type == 1 ? record.sessionInfo.avatar.mid : 0)
    }
    var folder: PiliIM_SessionPageType? {
      guard case .foldID(let f) = record.id.id else { return nil }
      switch f.type {
      case .group, .groupFold: return .group
      case .unfollowed: return .unfollowed
      case .stranger: return .stranger
      case .dustbin: return .dustbin
      case .customerAccount, .customerFold: return .customer
      case .aiFold: return .ai
      default: return nil
      }
    }
  }
  let uid: String
  var type = PiliIM_SessionPageType.home, title = "私信"
  var heading: AnyView? = nil
  var refreshed: (() async -> Void)? = nil
  @State private var menu: [PiliIM_ThreeDotItem] = []
  @State private var rev = 0
  @State private var needsReload = false
  @State private var error: String?
  @State private var pending: Pending?
  @State private var busy = false
  enum Pending {
    case read, delete
    case one(Conversation)
  }
  private var api: IMGateway { BiliAPI.shared.instantMessaging(for: uid) }
  var body: some View {
    PageList(empty: "暂无会话", heading: heading, refreshed: refreshed) { c in
      let p = try await api.sessions(type, cursor: c)
      try Task.checkCancellation()
      if c == nil {
        var seen = Set<String>()
        menu = (p.menu + p.outside).filter {
          seen.insert("\($0.type.rawValue):\($0.title)").inserted
        }
      }
      return Page(items: p.rows.map(Row.init), next: p.cursor)
    } row: { r in
      destination(r).contextMenu {
        if r.record.id.id != nil {
          Button(r.record.isPinned ? "取消置顶" : "置顶") { Task { await pin(r) } }
        }
        if let c = r.conversation, c.session_type == 1 {
          if r.record.hasUnread { Button("标为已读") { Task { await mark(c) } } }
          ContextLink("聊天设置", systemImage: "gearshape") { IMConversationSettings(conversation: c, uid: uid, name: r.name) }
          Button(r.record.isMuted ? "开启提醒" : "免打扰") { Task { await mutate(c, .mute) } }
          Button("删除", role: .destructive) { pending = .one(c) }
        }
        if r.record.sessionInfo.avatar.mid > 0 {
          NavigationLink("用户空间") {
            CreatorSpace(mid: r.record.sessionInfo.avatar.mid, name: r.name)
          }
        }
      }.swipeActions {
        if let c = r.conversation, c.session_type == 1 {
          Button("删除", role: .destructive) { pending = .one(c) }
        }
        if r.record.id.id != nil {
          Button(r.record.isPinned ? "取消置顶" : "置顶") { Task { await pin(r) } }
        }
      }
    }.id(rev).contextPushHost().navigationTitle(title)
      .onReceive(NotificationCenter.default.publisher(for: .piliIMChanged)) { n in
        if n.object as? String == uid { needsReload = true }
      }
      .onAppear {
        if needsReload {
          needsReload = false
          rev += 1
        }
      }
      .toolbar {
        Menu {
          ForEach(Array(menu.enumerated()), id: \.offset) { _, item in action(item) }
          if !menu.contains(where: { $0.type == .contacts }) {
            NavigationLink("通讯录") { IMContactBook(uid: uid) }
          }
          if !menu.contains(where: { $0.type == .msgSetting }) {
            NavigationLink("消息设置") { IMPreferences(uid: uid) }
          }
        } label: {
          Image(systemName: "ellipsis.circle").accessibilityLabel("会话操作")
        }.disabled(busy)
      }
      .confirmationDialog(
        confirmText,
        isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
        presenting: pending
      ) { p in
        switch p {
        case .read: Button("全部标为已读") { Task { await listAction(delete: false) } }
        case .delete:
          Button("清空此分类的会话", role: .destructive) { Task { await listAction(delete: true) } }
        case .one(let c): Button("删除会话", role: .destructive) { Task { await mutate(c, .delete) } }
        }
      }.alert("私信", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
        Button("好") {}
      } message: {
        Text(error ?? "")
      }
  }
  @ViewBuilder private func destination(_ r: Row) -> some View {
    if let c = r.conversation {
      PlainRowLink {
        ChatHistory(
          conversation: c, name: r.name, originUID: uid, live: r.record.sessionInfo.isLive)
      } label: {
        label(r)
      }
    } else if let f = r.folder, f != type {
      PlainRowLink {
        IMSessions(uid: uid, type: f, title: r.name)
      } label: {
        label(r)
      }
    } else if case .systemID(let v) = r.record.id.id, v.type == .system {
      PlainRowLink {
        NoticeFeed(kind: .system)
      } label: {
        label(r)
      }
    } else if let route = SharedLink.parse(r.record.chatURL) {
      PlainRowLink {
        LinkDestination(item: route)
      } label: {
        label(r)
      }
    } else if let u = httpsURL(r.record.chatURL) {
      PlainRowLink {
        SitePage(url: u)
      } label: {
        label(r)
      }
    } else {
      label(r)
    }
  }
  private var confirmText: String {
    switch pending {
    case .read: "将此分类全部标为已读？"
    case .delete: "清空此分类的所有会话？"
    case .one: "删除此会话？"
    case nil: "会话操作"
    }
  }
  @ViewBuilder private func action(_ item: PiliIM_ThreeDotItem) -> some View {
    switch item.type {
    case .readAll: Button(item.title.isEmpty ? "全部标为已读" : item.title) { pending = .read }
    case .clearList:
      Button(item.title.isEmpty ? "清空会话" : item.title, role: .destructive) { pending = .delete }
    case .msgSetting: NavigationLink("消息设置") { IMPreferences(uid: uid) }
    case .contacts: NavigationLink("通讯录") { IMContactBook(uid: uid) }
    case .upHelper:
      if let url = URL(string: item.url),
        let mid = url.pathComponents.compactMap(Int64.init).first(where: { $0 > 0 })
      {
        NavigationLink(item.title) {
          ChatHistory(
            conversation: .init(
              talker_id: mid, session_type: 1, unread_count: nil, last_msg: nil, serviceRecipient: 0
            ),
            name: item.title)
        }
      }
    default: if let url = httpsURL(item.url) { Link(item.title, destination: url) }
    }
  }
  private func label(_ r: Row) -> some View {
    let unread = r.record.unread
    let showsCount = r.record.hasUnread && unread.style == .number
    return SessionRowLabel(
      photo: r.photo, name: r.name,
      tag: r.record.sessionInfo.userLabel.style.borderedLabel.text,
      summary: r.record.msgSummary.prefixText + r.record.msgSummary.rawMsg,
      date: r.record.timestamp > 0
        ? Date(timeIntervalSince1970: Double(r.record.timestamp) / 1_000_000) : nil,
      unread: showsCount
        ? (unread.numberShow.isEmpty ? String(unread.number) : unread.numberShow) : nil,
      dot: r.record.hasUnread && !showsCount && unread.style != .none,
      live: r.record.sessionInfo.isLive, pinned: r.record.isPinned, muted: r.record.isMuted)
  }
  @MainActor private func mark(_ c: Conversation) async {
    guard !busy, c.session_type == 1 else { return }
    busy = true
    defer { busy = false }
    do {
      let n = try await api.readSequence(talker: c.talker_id)
      try await BiliAPI.shared.acknowledge(c, n, expectedUser: uid)
      rev += 1
    } catch { self.error = error.localizedDescription }
  }
  @MainActor private func pin(_ r: Row) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      try await api.pin(r.record.id, enabled: !r.record.isPinned)
      rev += 1
    } catch { self.error = error.localizedDescription }
  }
  @MainActor private func listAction(delete: Bool) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      if delete { try await api.deleteSessions(type) } else { try await api.clearUnread(type) }
      NotificationCenter.default.post(name: .piliUnreadChanged, object: nil)
      rev += 1
    } catch { self.error = error.localizedDescription }
  }
  @MainActor private func mutate(_ c: Conversation, _ op: BiliAPI.IMMutation) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      try await BiliAPI.shared.modifySession(c, op, user: uid)
      rev += 1
    } catch { self.error = error.localizedDescription }
  }
}
