import SwiftUI

struct MomentOwnerSettings: View {
  let entry: DynamicEntry, uid: String
  var changed: () -> Void
  @EnvironmentObject private var accounts: AccountContext
  @State private var permissions: Permissions?
  @State private var visibility: Bool?
  @State private var confirmPublic = false
  @State private var busy = false
  @State private var reload = 0
  @State private var issue: String?
  struct Permissions: Decodable {
    struct Rule: Decodable { let status: Int, can_modify: Bool }
    let up_reply_selection, up_reply: Rule
  }
  var body: some View {
    Form {
      if let issue {
        Section {
          Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.red)
          Button("重试") { reload += 1 }
        }
      }
      if available {
        Section {
          if let visibility {
            SettingToggle(
              title: "仅自己可见", symbol: "eye.slash", color: .orange,
              isOn: Binding(get: { visibility }, set: { on in
                if on { Task { await publish(privateOnly: true) } } else { confirmPublic = true }
              }))
          } else if issue == nil {
            ProgressView().frame(maxWidth: .infinity)
          }
        } header: {
          Text("可见范围")
        } footer: {
          Text("仅自己可见的动态不会出现在粉丝的动态页")
        }
        if entry.replyOID != nil, entry.replyType != nil {
          Section {
            if let p = permissions {
              SettingToggle(
                title: "评论精选", symbol: "star.bubble", color: .yellow,
                isOn: Binding(get: { p.up_reply_selection.status == 1 }, set: { on in
                  Task { await modify(on ? 1 : 2) }
                })
              ).disabled(!p.up_reply_selection.can_modify)
              SettingToggle(
                title: "关闭评论", symbol: "bubble.left.and.exclamationmark.bubble.right", color: .red,
                isOn: Binding(get: { p.up_reply.status != 1 }, set: { on in
                  Task { await modify(on ? 3 : 4) }
                })
              ).disabled(!p.up_reply.can_modify)
            } else if issue == nil {
              ProgressView().frame(maxWidth: .infinity)
            }
          } header: {
            Text("评论")
          } footer: {
            Text("开启精选后，只有你选中的评论会公开显示")
          }
        }
      } else {
        ContentUnavailableView("账号已切换", systemImage: "person.crop.circle.badge.exclamationmark")
      }
    }.disabled(busy).navigationTitle("动态管理").navigationBarTitleDisplayMode(.inline)
      .confirmationDialog("让所有人查看这条动态？", isPresented: $confirmPublic) {
        Button("改为公开") { Task { await publish(privateOnly: false) } }
      }
      .task(id: "\(uid):\(accounts.state.active ?? ""):\(reload)") {
        permissions = nil
        issue = nil
        guard available else { return }
        do {
          let row = try await BiliAPI.shared.mainDynamicRow(entry.id, owner: uid)
          try Task.checkCancellation()
          guard let author = (row["modules"] as? [String: Any])?["module_author"] as? [String: Any],
            DynamicRevision.number(author["mid"]) == uid
          else { throw ServiceError("只能管理自己的动态") }
          visibility = DynamicRevision.ownerPrivate(author)
        } catch {
          if !Task.isCancelled { issue = error.localizedDescription }
          return
        }
        guard let oid = entry.replyOID, let type = entry.replyType else { return }
        do {
          let p = try await BiliAPI.shared.read(
            "/x/v2/reply/subject/interaction-status",
            ["oid": String(oid), "type": String(type), "web_location": "333.1369"],
            expectedAccount: uid, as: Permissions.self)
          try Task.checkCancellation()
          if available { permissions = p }
        } catch { if !Task.isCancelled, available { issue = error.localizedDescription } }
      }
  }
  private var available: Bool {
    accounts.state.active == uid && entry.authorID.map(String.init) == uid
  }
  @MainActor private func modify(_ action: Int) async {
    guard available, !busy, let p = permissions, let oid = entry.replyOID,
      let type = entry.replyType
    else { return }
    let rule = action <= 2 ? p.up_reply_selection : p.up_reply
    guard rule.can_modify else { return }
    busy = true
    defer { busy = false }
    do {
      try await BiliAPI.shared.submit(
        "/x/v2/reply/subject/modify",
        ["oid": String(oid), "type": String(type), "action": String(action)], expectedAccount: uid)
      if available {
        changed()
        reload += 1
      }
    } catch { if available { issue = error.localizedDescription } }
  }
  @MainActor private func publish(privateOnly: Bool) async {
    guard available, !busy else { return }
    busy = true
    issue = nil
    defer { busy = false }
    do {
      let row = try await BiliAPI.shared.mainDynamicRow(entry.id, owner: uid)
      guard available,
        let author = (row["modules"] as? [String: Any])?["module_author"] as? [String: Any],
        DynamicRevision.number(author["mid"]) == uid
      else { throw ServiceError("动态归属已变更") }
      let current = DynamicRevision.ownerPrivate(author)
      if current == privateOnly {
        visibility = current
        changed()
        return
      }
      if current != visibility {
        visibility = current
        throw ServiceError("可见范围已变更，请重新确认")
      }
      let data = try JSONSerialization.data(withJSONObject: ["dyn_id": entry.id])
      _ = try await BiliAPI.shared.dynPost(
        "/x/dynamic/feed/dyn/private_pub_setting",
        [
          "object_id": String(decoding: data, as: UTF8.self),
          "action": privateOnly ? "private_pub" : "public_pub",
        ], expectedAccount: uid)
      if available {
        visibility = privateOnly
        changed()
      }
    } catch { if available { issue = error.localizedDescription } }
  }
}
