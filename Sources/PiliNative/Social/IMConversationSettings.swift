import PiliWire

import SwiftUI

extension BiliAPI {
  struct IMOther: Decodable { let mid: Int64, name: String?, face: String?, sign: String? }
  struct IMPushState: Decodable {
    let follow_status: Int?, push_setting: Int?, show_push_setting: Int?
  }
  func imPeople(_ ids: [Int64], owner: String) async throws -> [IMOther] {
    let ids = Array(Set(ids.filter { $0 > 0 })).sorted()
    guard !ids.isEmpty else { return [] }
    var people = [Int64: IMOther]()
    var failure: Error?
    // These are cookie-authenticated GETs, not settings mutations: no CSRF prerequisite.
    for start in stride(from: 0, to: ids.count, by: 50) {
      try Task.checkCancellation()
      let batch = Array(ids[start..<min(start + 50, ids.count)])
      let path = "/x/im/user_infos"
      do {
        let values = try await read(
          path, ["uids": batch.map(String.init).joined(separator: ","), "build": "0", "mobi_app": "web"],
          host: "api.vc.bilibili.com", expectedAccount: owner, as: [IMOther].self)
        for value in values where batch.contains(value.mid) { people[value.mid] = value }
      } catch {
        try Task.checkCancellation()
        failure = error
        await DiagnosticJournal.shared.add("消息", "\(path) · \(String(describing: error))")
      }
      let missing = batch.filter { people[$0] == nil }
      if !missing.isEmpty {
        // The current web message client uses UID-keyed cards, unlike user_infos' array.
        let path = "/x/polymer/pc-electron/v1/user/cards"
        do {
          let cards = try await read(
            path, ["uids": missing.map(String.init).joined(separator: ","), "build": "0", "mobi_app": "web"],
            expectedAccount: owner, as: [String: IMOther].self)
          for id in missing {
            if let card = cards[String(id)], card.mid == id { people[id] = card }
          }
        } catch {
          try Task.checkCancellation()
          failure = error
          await DiagnosticJournal.shared.add("消息", "\(path) · \(String(describing: error))")
        }
      }
    }
    try Task.checkCancellation()
    guard try await AccountJar.shared.current()?.id == owner else { throw ServiceError("账号已切换") }
    let missing = ids.count - people.count
    if missing > 0 {
      await DiagnosticJournal.shared.add("消息", "会话资料缺少 \(missing)/\(ids.count) 项")
    }
    if people.isEmpty { throw failure ?? ServiceError("没有返回会话用户资料") }
    return ids.compactMap { people[$0] }
  }
  func imSettingsRead<T: Decodable>(
    _ path: String, _ query: [String: String], owner: String, as: T.Type
  ) async throws -> T {
    guard
      [
        "/x/im/user_infos", "/link_setting/v1/link_setting/get_session_ss",
        "/link_setting/v1/link_setting/get_msg_dnd",
      ].contains(path), let a = try await AccountJar.shared.current(), a.id == owner,
      let csrf = a.csrf
    else { throw ServiceError("请重新登录") }
    var f = query
    f["csrf"] = csrf
    f["csrf_token"] = csrf
    f["build"] = "0"
    f["mobi_app"] = "web"
    return try await read(path, f, host: "api.vc.bilibili.com", expectedAccount: owner, as: T.self)
  }
  func imPeerPush(_ target: Int64, enabled: Bool, owner: String) async throws {
    guard target > 0, let a = try await AccountJar.shared.current(), a.id == owner else {
      throw ServiceError("账号已切换")
    }
    _ = try await messageForm(
      "/link_setting/v1/link_setting/set_push_ss",
      fields: ["talker_uid": String(target), "setting": enabled ? "0" : "1"], query: [:], account: a
    )
  }
}
extension Notification.Name { static let piliIMChanged = Self("PiliNative.IMChanged") }
struct IMConversationSettings: View {
  let conversation: Conversation, uid: String
  var name: String?
  @EnvironmentObject private var accounts: AccountContext
  @State private var person: BiliAPI.IMOther?
  @State private var push: BiliAPI.IMPushState?
  @State private var muted: Bool?
  @State private var pinned: Bool?
  @State private var pending: Intent?
  @State private var busy = false
  @State private var revision = 0
  @State private var issue: String?
  enum Intent { case disablePush, block }
  private var target: Int64 { conversation.talker_id }
  private var mobile: Bool {
    accounts.state.accounts.first(where: { $0.id == uid })?.mobileToken?.isEmpty == false
  }
  private var api: IMGateway { BiliAPI.shared.instantMessaging(for: uid) }
  private var id: PiliIM_SessionId {
    var k = PiliIM_SessionId()
    k.privateID.talkerUid = target
    return k
  }
  var body: some View {
    Form {
      if uid == accounts.state.active, conversation.session_type == 1, target > 0 {
        NavigationLink {
          CreatorSpace(mid: target, name: person?.name ?? name ?? "用户空间")
        } label: {
          VStack(alignment: .leading) {
            Text(person?.name ?? name ?? "UID \(target)")
            if let s = person?.sign, !s.isEmpty {
              Text(s).piliFont(.caption).foregroundStyle(.secondary)
            }
          }
        }
        if let p = push, p.show_push_setting == 1, let setting = p.push_setting,
          [0, 1].contains(setting)
        {
          Toggle(
            "接收内容推送",
            isOn: .init(
              get: { setting == 0 },
              set: { on in
                if !on { pending = .disablePush } else { Task { await change(.push(true)) } }
              }))
        }
        if let pinned {
          Toggle("置顶聊天", isOn: .init(get: { pinned }, set: { v in Task { await change(.pin(v)) } }))
        }
        if let muted {
          Toggle(
            "消息免打扰", isOn: .init(get: { muted }, set: { v in Task { await change(.mute(v)) } }))
        }
        if let push {
          Toggle(
            "加入黑名单",
            isOn: .init(
              get: { push.follow_status == 128 },
              set: { v in if v { pending = .block } else { Task { await change(.block(false)) } } })
          )
        }
        NavigationLink("举报用户") { CommunityReport(target: .person(id: target), uid: uid) }
        if let issue {
          Text(issue)
          Button("重新载入") { revision += 1 }
        }
      } else {
        Text("账号已切换")
      }
    }.disabled(busy).navigationTitle("聊天设置").task(id: "\(uid):\(target):\(revision)") {
      await load()
    }
    .confirmationDialog(
      pending == .block ? "将此用户加入黑名单？" : "关闭此账号的内容推送？",
      isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
      presenting: pending
    ) { i in
      Button("确认", role: .destructive) {
        Task { await change(i == .block ? .block(true) : .push(false)) }
      }
    } message: { i in
      Text(i == .block ? "双方的关注和合集订阅也会解除" : "仍会收到通知类消息")
    }
  }
  enum Change {
    case push(Bool)
    case pin(Bool)
    case mute(Bool)
    case block(Bool)
  }
  private struct Mutes: Decodable {
    struct Entry: Decodable { let uid: Int64?, setting: Int? }
    let uid_settings: [Entry]?
  }
  @MainActor private func load() async {
    guard uid == accounts.state.active, conversation.session_type == 1 else { return }
    busy = true
    defer { busy = false }
    issue = nil
    var absent = [String]()
    func capture<T>(_ label: String, _ f: () async throws -> T) async -> T? {
      do { return try await f() } catch {
        if !Task.isCancelled { absent.append(label) }
        return nil
      }
    }
    let api = BiliAPI.shared
    let p = await capture("用户资料") { try await api.imPeople([target], owner: uid) }
    guard !Task.isCancelled, uid == accounts.state.active else { return }
    person = p?.first { $0.mid == target }
    push = await capture("内容推送和黑名单") {
      try await api.imSettingsRead(
        "/link_setting/v1/link_setting/get_session_ss", ["talker_uid": String(target)], owner: uid,
        as: BiliAPI.IMPushState.self)
    }
    let m = await capture("免打扰") {
      try await api.imSettingsRead(
        "/link_setting/v1/link_setting/get_msg_dnd", ["own_uid": uid, "uids_str": String(target)],
        owner: uid, as: Mutes.self)
    }
    guard !Task.isCancelled, uid == accounts.state.active else { return }
    let matching = m?.uid_settings?.first(where: {
      $0.uid == target || $0.uid == nil && m?.uid_settings?.count == 1
    })
    muted =
      matching?.setting.flatMap { [0, 1].contains($0) ? $0 == 1 : nil }
      ?? conversation.is_dnd.map { $0 == 1 }
    if mobile {
      pinned = await capture("置顶状态") { try await self.api.session(id).isPinned }
    } else if let ts = conversation.top_ts {
      pinned = pinned ?? (ts > 0)
    } else {
      let page = await capture("置顶状态") { try await api.conversations(cursor: nil, owner: uid) }
      pinned = page?.items.first(where: { $0.id == conversation.id }).map { ($0.top_ts ?? 0) > 0 }
    }
    if !Task.isCancelled, !absent.isEmpty { issue = "未能读取：" + absent.joined(separator: "、") }
  }
  @MainActor private func change(_ item: Change) async {
    guard !busy, uid == accounts.state.active, target > 0, conversation.session_type == 1 else {
      return
    }
    busy = true
    defer { busy = false }
    do {
      switch item {
      case .push(let v):
        guard push?.show_push_setting == 1 else { return }
        try await BiliAPI.shared.imPeerPush(target, enabled: v, owner: uid)
      case .block(let v):
        guard push != nil else { return }
        try await BiliAPI.shared.submit(
          "/x/relation/modify", ["fid": String(target), "act": v ? "5" : "6", "re_src": "11"],
          expectedAccount: uid)
      case .pin(let v):
        guard let p = pinned, v != p else { return }
        if mobile {
          try await api.pin(id, enabled: v)
        } else {
          var c = conversation
          c.top_ts = p ? 1 : 0
          try await BiliAPI.shared.modifySession(c, .pin, user: uid)
        }
        pinned = v
      case .mute(let v):
        guard let m = muted, v != m else { return }
        var c = conversation
        c.is_dnd = m ? 1 : 0
        try await BiliAPI.shared.modifySession(c, .mute, user: uid)
        muted = v
      }
      NotificationCenter.default.post(name: .piliIMChanged, object: uid)
      if case .push = item { revision += 1 }
      if case .block = item { revision += 1 }
    } catch { if uid == accounts.state.active { issue = error.localizedDescription } }
  }
}
