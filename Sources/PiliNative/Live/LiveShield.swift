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
  var body: some View {
    Form {
      Picker("屏蔽范围", selection: $people) {
        Text("关键词").tag(false)
        Text("用户").tag(true)
      }.pickerStyle(.segmented).onChange(of: people) { _, _ in draft = "" }
      HStack {
        TextField(people ? "输入 UID" : "输入关键词", text: $draft).keyboardType(
          people ? .numberPad : .default)
        Button("添加") {
          let s = draft.trimmingCharacters(in: .whitespacesAndNewlines)
          Task { await change(people, s, adding: true) }
        }.disabled(
          draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (people && (Int64(draft) ?? 0) <= 0))
      }
      if let issue {
        Text(issue)
        Button("重新载入") { reload += 1 }
      }
      if busy || loading { ProgressView() }
      if people {
        ForEach(rules?.shield_user_list ?? []) { u in
          HStack {
            Text(u.uname ?? "用户")
            Spacer()
            Text(String(u.uid)).foregroundStyle(.secondary)
          }.swipeActions {
            Button("移除", role: .destructive) {
              Task { await change(true, String(u.uid), adding: false) }
            }
          }
        }
      } else {
        ForEach(rules?.keyword_list ?? [], id: \.self) { word in
          Text(word).swipeActions {
            Button("移除", role: .destructive) { Task { await change(false, word, adding: false) } }
          }
        }
      }
    }.disabled(busy || loading).navigationTitle("直播弹幕屏蔽").task(id: reload) {
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
