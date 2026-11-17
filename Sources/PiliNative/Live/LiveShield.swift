import SwiftUI

struct LiveShield: Decodable {
  struct User: Decodable, Identifiable {
    let uid: Int64, uname: String?
    var id: Int64 { uid }
  }
  let keyword_list: [String]?, shield_user_list: [User]?
  func adding(_ uid: Int64, name: String) -> Self {
    var users = shield_user_list ?? []
    if !users.contains(where: { $0.uid == uid }) { users.append(.init(uid: uid, uname: name)) }
    return .init(keyword_list: keyword_list, shield_user_list: users)
  }
  func hides(_ line: LiveLine) -> Bool {
    if let uid = line.uid, shield_user_list?.contains(where: { $0.uid == uid }) == true {
      return true
    }
    return keyword_list?.contains(where: { !$0.isEmpty && line.text.contains($0) }) == true
  }
}
extension BiliAPI {
  func shield(room: Int64, user: String) async throws -> LiveShield {
    struct Response: Decodable { let shield_info: LiveShield? }
    let path = "/xlive/web-room/v1/index/getInfoByUser"
    let q = try await sign([
      "room_id": String(room), "from": "0", "not_mock_enter_effect": "1", "web_location": "444.8",
    ])
    let bytes: Data
    if try await AccountJar.shared.current(.role(.heartbeat))?.id == user {
      bytes = try await fetch(path, q, host: "api.live.bilibili.com", expectedAccount: user)
    } else {
      // Personal shield edits always use the primary account, including when playback uses a guest.
      guard let main = try await AccountJar.shared.current(), main.id == user else {
        throw ServiceError("账号已切换")
      }
      var c = URLComponents()
      c.scheme = "https"
      c.host = "api.live.bilibili.com"
      c.path = path
      c.queryItems = q.map(URLQueryItem.init)
      guard let u = c.url else { throw URLError(.badURL) }
      var req = URLRequest(url: u, timeoutInterval: 18)
      req.setValue(main.header, forHTTPHeaderField: "Cookie")
      req.setValue("https://live.bilibili.com/" + String(room), forHTTPHeaderField: "Referer")
      let (data, response) = try await webResponse(req, identity: main)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw ServiceError("无法读取直播屏蔽设置")
      }
      bytes = data
    }
    struct Reply: Decodable { let code: Int, message: String?, data: Response? }
    let r = try JSONDecoder().decode(Reply.self, from: bytes)
    guard r.code == 0, let data = r.data else { throw ServiceError(r.message ?? "无法读取直播屏蔽设置") }
    return data.shield_info ?? LiveShield(keyword_list: [], shield_user_list: [])
  }
}
struct LiveShieldView: View {
  let room: Int64, user: String
  @Binding var rules: LiveShield?
  @State private var people = false
  @State private var draft = ""
  @State private var busy = false
  @State private var loading = true
  @State private var issue: String?
  @State private var reload = 0
  @State private var adding = false
  @State private var removing: (Bool, String, String)?
  var body: some View {
    let keywords = rules?.keyword_list ?? []
    let users = rules?.shield_user_list ?? []
    let empty = people ? users.isEmpty : keywords.isEmpty
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if let issue {
          HStack {
            Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.red)
            Spacer()
            Button("重新载入") { reload += 1 }
          }
          .font(.footnote)
        }
        WrappingActions(spacing: 10, rowSpacing: 10) {
          if people {
            ForEach(users) { u in
              chip(u.uname ?? String(u.uid)) { removing = (true, String(u.uid), u.uname ?? String(u.uid)) }
            }
          } else {
            ForEach(keywords, id: \.self) { word in
              chip(word) { removing = (false, word, word) }
            }
          }
        }
      }
      .padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }
    .overlay {
      if loading && rules == nil { ProgressView() }
      else if empty && !loading { ContentUnavailableView(people ? "暂无屏蔽用户" : "暂无屏蔽关键词", systemImage: "text.badge.xmark") }
    }
    .pinnedHeader {
      ChipBar(items: [false, true], selection: $people) {
        $0 ? "用户(\(users.count))" : "关键词(\(keywords.count))"
      }
    }
    .floatingAction("添加", systemImage: "plus", disabled: busy || loading) { draft = ""; adding = true }
    .onChange(of: people) { _, _ in draft = "" }
    .alert(people ? "用户屏蔽" : "关键词屏蔽", isPresented: $adding) {
      TextField(people ? "UID" : "关键词", text: $draft).keyboardType(people ? .numberPad : .default)
      Button("取消", role: .cancel) {}
      Button("确定") {
        let s = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await change(people, s, adding: true) }
      }.disabled(
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || (people && (Int64(draft) ?? 0) <= 0))
    }
    .confirmationDialog("确定删除该规则？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
      titleVisibility: .visible, presenting: removing) { r in
      Button("删除 " + r.2, role: .destructive) { Task { await change(r.0, r.1, adding: false) } }
    }
    .disabled(busy || loading).navigationTitle("弹幕屏蔽").navigationBarTitleDisplayMode(.inline).task(id: reload) {
      loading = true
      defer { if !Task.isCancelled { loading = false } }
      do {
        let fresh = try await BiliAPI.shared.shield(room: room, user: user)
        try Task.checkCancellation()
        rules = fresh
        issue = nil
      } catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
  }
  private func chip(_ text: String, remove: @escaping () -> Void) -> some View {
    Button(action: remove) {
      HStack(spacing: 6) {
        Text(text).lineLimit(1)
        Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
      }
      .font(.subheadline).padding(.horizontal, 12).padding(.vertical, 7)
      .background(Color(uiColor: .secondarySystemFill), in: Capsule())
    }
    .buttonStyle(.plain).accessibilityHint("删除这条规则")
  }
  @MainActor private func change(_ people: Bool, _ value: String, adding: Bool) async {
    guard !busy, !value.isEmpty else { return }
    busy = true
    defer { busy = false }
    do {
      let api = BiliAPI.shared
      if people {
        guard let target = Int64(value) else { throw ServiceError("请输入有效的 UID") }
        try await api.changeLiveShield(room: room, sender: target, adding: adding, owner: user)
      } else {
        let path =
          "/xlive/web-ucenter/v1/banned/" + (adding ? "AddShieldKeyword" : "DelShieldKeyword")
        try await api.submit(path, ["keyword": value], expectedAccount: user, service: .live)
      }
      draft = ""
      rules = try await api.shield(room: room, user: user)
      issue = nil
    } catch { issue = error.localizedDescription }
  }
}
