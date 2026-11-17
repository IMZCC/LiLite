import SwiftUI

struct IMMessageReport: View {
  let uid: String, sender: Int64, key: String
  @State private var reason: Int?
  @State private var note = ""
  @State private var busy = false
  @State private var confirm = false
  @State private var submitted = false
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss
  private static let reasons = [
    (1, "色情低俗"), (2, "政治敏感"), (3, "违法有害"), (4, "广告骚扰"), (5, "人身攻击"), (6, "诈骗"), (0, "其他问题"),
  ]
  var body: some View {
    Form {
      if submitted {
        Section {
          VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(.green)
            Text("举报已提交").font(.headline)
          }
          .frame(maxWidth: .infinity).padding(.vertical, 12)
        }
      } else {
        Section("举报原因") {
          ForEach(Self.reasons, id: \.0) { id, title in
            Button {
              reason = id
            } label: {
              HStack(spacing: 12) {
                Image(systemName: reason == id ? "largecircle.fill.circle" : "circle")
                  .foregroundStyle(reason == id ? Color.accentColor : Color.secondary)
                Text(title).foregroundStyle(.primary)
                Spacer()
              }
              .contentShape(Rectangle())
            }
            .accessibilityAddTraits(reason == id ? .isSelected : [])
          }
        }
        Section(reason == 0 ? "问题说明" : "补充说明（选填）") {
          TextField("描述这条消息的问题", text: $note, axis: .vertical).lineLimit(2...6)
        }
        Section {
          Button {
            confirm = true
          } label: {
            HStack {
              Text("提交举报").fontWeight(.semibold)
              if busy { Spacer(); ProgressView() }
            }
          }
          .foregroundStyle(.red)
          .disabled(
            reason == nil
              || (reason == 0 && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        } footer: {
          if let error { Text(error).foregroundStyle(.red) }
        }
      }
    }.navigationTitle("举报私信").navigationBarTitleDisplayMode(.inline).disabled(busy).toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button(submitted ? "完成" : "取消") { dismiss() }.disabled(busy)
      }
    }.confirmationDialog("提交对这条消息的举报？", isPresented: $confirm) {
      Button("提交举报", role: .destructive) { Task { await submit() } }
    }
  }
  @MainActor private func submit() async {
    guard !busy, !submitted, let reason,
      let label = Self.reasons.first(where: { $0.0 == reason })?.1
    else { return }
    busy = true
    error = nil
    defer { busy = false }
    let desc = note.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      guard let identity = try await AccountJar.shared.current(), identity.id == uid,
        String(sender) != uid,
        sender > 0, IMHistoryPolicy.key(key) != nil, reason != 0 || !desc.isEmpty
      else { throw ServiceError("消息或账号已变更") }
      let comment = try JSONSerialization.data(withJSONObject: ["group_id": 0, "msg_key": key])
      _ = try await BiliAPI.shared.messageForm(
        "/x/bplus/im/report/add",
        fields: [
          "biz_code": "4", "accused_uid": String(sender), "object_id": String(sender),
          "reason_type": String(reason), "reason_desc": desc.isEmpty ? label : desc,
          "module": "604", "comment": String(decoding: comment, as: UTF8.self),
          "extra": "{\"msg_keys\":[]}",
        ], query: [:], account: identity)
      submitted = true
    } catch { self.error = error.localizedDescription }
  }
}
