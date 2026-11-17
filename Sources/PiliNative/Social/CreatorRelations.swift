import SwiftUI

struct CreatorRelation: Decodable {
  let attribute: Int?, tag: [Int]?, special: Int?, mtime: Int64?
  var followed: Bool { attribute == 2 || attribute == 6 || attribute == 1 }
}
struct SharedFollowing: View {
  let mid: Int64, uid: String
  let alsoFollowsCreator: Bool
  @EnvironmentObject private var accounts: AccountContext
  @State private var remoteName: String?
  @State private var total: Int?
  var body: some View {
    VStack(alignment: .leading) {
      if let total {
        Text("共 \(total) 人").piliFont(.caption).foregroundStyle(.secondary).padding(.horizontal)
      }
      PageList(empty: "暂无用户") { cursor in
        let fields = (cursor ?? "1:0").split(separator: ":")
        let page = Int(fields.first ?? "1") ?? 1
        let offset = Int(fields.last ?? "0") ?? 0
        struct Result: Decodable { let list: [Creator]?, total: Int? }
        guard let account = try await AccountJar.shared.current(), account.id == uid,
          let csrf = account.csrf
        else { throw ServiceError("请重新登录") }
        let r = try await BiliAPI.shared.read(
          alsoFollowsCreator
            ? "/x/relation/followings/followed_upper" : "/x/relation/same/followings",
          ["vmid": String(mid), "pn": String(page), "csrf": csrf, "web_location": "333.789"],
          expectedAccount: uid, as: Result.self)
        try Task.checkCancellation()
        total = r.total
        let rows = r.list ?? []
        let seen = offset + rows.count
        return Page(
          items: rows, next: !rows.isEmpty && seen < (r.total ?? 0) ? "\(page+1):\(seen)" : nil)
      } row: { person in
        CreatorLink(person: person)
      }
    }.navigationTitle(alsoFollowsCreator ? "我关注的" + (total.map(String.init) ?? "") + "人也关注了" + (remoteName ?? "TA") : (remoteName.map { "我与" + $0 + "的" } ?? "") + "共同关注")
    .task(id: "\(mid):\(accounts.state.active ?? "")") {
      remoteName = nil
      guard accounts.state.active == uid else { return }
      let name = try? await BiliAPI.shared.creatorCardName(String(mid), owner: uid)
      if !Task.isCancelled, accounts.state.active == uid { remoteName = name }
    }
  }
}
struct CreatorGroupEditor: View {
  let mid: Int64, uid: String
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var accounts: AccountContext
  @State private var naming = false
  @State private var name = ""
  @State private var groups: [FollowGroup] = []
  @State private var original = Set<Int>()
  @State private var selected = Set<Int>()
  @State private var loaded = false
  @State private var busy = false
  @State private var issue: String?
  var body: some View {
    Form {
      if !loaded && issue == nil { ProgressView() }
      if let issue {
        Text(issue)
        if !loaded { Button("重试") { Task { await load() } } }
      }
      if loaded {
        if selected.isEmpty { Label("默认分组", systemImage: "checkmark.circle.fill") }
        ForEach(groups) { g in
          Button {
            if !selected.insert(g.tagid).inserted { selected.remove(g.tagid) }
          } label: {
            HStack {
              VStack(alignment: .leading) {
                Text(g.name ?? "分组")
                if let tip = g.tip, !tip.isEmpty { Text(tip).piliFont(.caption).foregroundStyle(.secondary) }
              }
              Spacer()
              if let count = g.count {
                Text(
                  String(
                    max(
                      0,
                      count + (selected.contains(g.id) ? 1 : 0) - (original.contains(g.id) ? 1 : 0))
                  )
                ).foregroundStyle(.secondary)
              }
              Image(systemName: selected.contains(g.id) ? "checkmark.circle.fill" : "circle")
            }
          }
        }
        if !selected.isEmpty { Button("移至默认分组") { selected = [] } }
      }
    }.navigationTitle("设置关注分组").disabled(busy)
      .toolbar {
        Button("新建分组") { name = ""; naming = true }.disabled(!loaded || busy)
        Button(selected.isEmpty ? "保存至默认分组" : "保存") { Task { await save() } }.disabled(!loaded || busy)
      }
      .alert("新建分组", isPresented: $naming) {
        TextField("分组名称", text: $name)
        Button("取消", role: .cancel) {}
        Button("创建") { Task { await add() } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 16)
      }
      .task(id: uid) { await load() }
  }
  @MainActor private func load() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      let api = BiliAPI.shared
      async let list = api.read(
        "/x/relation/tags", [:], expectedAccount: uid, as: [FollowGroup].self)
      async let current = api.read(
        "/x/relation", ["fid": String(mid)], expectedAccount: uid, as: CreatorRelation.self)
      let (rows, rel) = try await (list, current)
      try Task.checkCancellation()
      guard rel.followed else { throw ServiceError("请先关注这位用户") }
      groups = rows.filter { $0.tagid != 0 }
      original = Set((rel.tag ?? []).filter { $0 != 0 })
      selected = original
      loaded = true
      issue = nil
    } catch { if !Task.isCancelled { issue = error.localizedDescription } }
  }
  @MainActor private func add() async {
    guard !busy, loaded, accounts.state.active == uid else { return }
    busy = true; defer { busy = false }
    do {
      let cmd = try FollowGroupCommand(.add(name), owner: uid)
      try cmd.check(active: accounts.state.active)
      struct Reply: Decodable { struct Item: Decodable { let tagid: Int }; let data: Item }
      let bytes = try await BiliAPI.shared.submitResponse(cmd.path, cmd.fields, expectedAccount: uid)
      let tag = try JSONDecoder().decode(Reply.self, from: bytes).data.tagid
      try cmd.check(active: accounts.state.active)
      guard tag > 0, FollowGroupCommand.custom(tag) else { throw ServiceError("分组编号无效") }
      if !groups.contains(where: { $0.id == tag }) {
        groups.append(.init(tagid: tag, name: cmd.fields["tag"], count: 0))
      }
      selected.insert(tag); issue = nil
    } catch { if accounts.state.active == uid { issue = error.localizedDescription } }
  }
  @MainActor private func save() async {
    guard !busy, loaded else { return }
    TouchFeedback.light()
    busy = true
    defer { busy = false }
    do {
      try await BiliAPI.shared.submit(
        "/x/relation/tags/addUsers",
        [
          "fids": String(mid),
          "tagids": selected.isEmpty
            ? "0" : selected.sorted().map(String.init).joined(separator: ","),
        ], expectedAccount: uid)
      dismiss()
    } catch { issue = error.localizedDescription }
  }
}
