import SwiftUI
import UniformTypeIdentifiers

struct LiveActionSelection: Identifiable {
  let id = UUID()
  let line: LiveLine, paid: SuperChatMessage?, room: Int64, owner: String?
}
struct LiveMessageRow: View {
  let line: LiveLine
  var anchor: Int64? = nil
  @AppStorage("live.medal") private var medal = true
  /// The message as text and emote nodes (LiveChatLine draws them too).
  var nodes: [RichNode] {
    func node(_ token: String, _ raw: String) -> RichNode {
      guard let url = GalleryPicture.source(raw) else { return .init(text: token) }
      return .init(
        text: token,
        emote: .init(name: token, url: url, size: 1, jump: nil, jumpTitle: nil, animation: nil))
    }
    if let e = line.emote { return [node(line.text, e)] }
    let keys = line.inlineEmotes.keys.filter { !$0.isEmpty }
    var text = line.text[...]
    var result = [RichNode]()
    while !text.isEmpty {
      let hits = keys.compactMap { key in text.range(of: key).map { (key, $0) } }
      guard
        let (key, range) = hits.min(by: { l, r in
          l.1.lowerBound == r.1.lowerBound
            ? l.1.upperBound > r.1.upperBound : l.1.lowerBound < r.1.lowerBound
        })
      else {
        result.append(.init(text: String(text)))
        break
      }
      if range.lowerBound > text.startIndex {
        result.append(.init(text: String(text[..<range.lowerBound])))
      }
      result.append(node(key, line.inlineEmotes[key]!))
      text = text[range.upperBound...]
    }
    return result
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        if let anchor, anchor == line.uid { Text("主播").foregroundStyle(.tint) }
        if medal, let badge = line.medal { Text(badge).foregroundStyle(.tint) }
        Text(line.name)
        if let name = line.repliedName { Text("回复 @" + name) }
        Spacer(minLength: 0)
        Image(systemName: "ellipsis").accessibilityHidden(true)
      }.piliFont(.caption).foregroundStyle(.secondary)
      if line.emote != nil || !line.inlineEmotes.isEmpty {
        ReplyRichText(nodes: nodes, permitsPreview: false)
      } else {
        Text(line.text).foregroundStyle(line.highlight ? Color.orange : .primary)
      }
    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
  }
}
struct LiveChatActions: View {
  let selection: LiveActionSelection
  @Binding var shield: LiveShield?
  var reply: ((LiveReplyTarget) -> Void)? = nil
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.dismiss) private var systemDismiss
  @Environment(\.roomPanelClose) private var panelClose
  @State private var confirm = false
  @State private var busy = false
  @State private var issue: String?
  private var line: LiveLine { selection.line }
  /// In the room's panel, closing closes the panel (dismiss would leave the room).
  private func dismiss() { if let panelClose { panelClose(()) } else { systemDismiss() } }
  private var owner: String? { selection.owner == accounts.state.active ? selection.owner : nil }
  var body: some View {
    if panelClose != nil { form } else { PiliNavigationStack { form } }
  }
  private var form: some View {
      Form {
        Section {
          Text(line.name).font(.headline)
          Text(line.text)
        }
        if let uid = line.uid, uid > 0 {
          NavigationLink("查看发送者主页") { DeferredPage { CreatorSpace(mid: uid, name: line.name) } }
        }
        if let to = line.repliedUID, let name = line.repliedName {
          NavigationLink("被回复者 @" + name) { CreatorSpace(mid: to, name: name) }
        }
        Button("复制留言信息") {
          let value =
            selection.paid.flatMap { try? $0.copyInfo(room: selection.room) }.map {
              String(decoding: $0, as: UTF8.self)
            } ?? line.copyInfo()
          UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: value]], options: [.localOnly: true])
          dismiss()
        }
        if let owner, let reply, let target = line.reply(room: selection.room, account: owner) {
          Button("回复 @" + line.name) {
            reply(target)
            dismiss()
          }
        }
        if let owner, line.room == selection.room {
          if let uid = line.uid, uid > 0, String(uid) != owner {
            Button("屏蔽这位用户", role: .destructive) { confirm = true }
          }
          if selection.paid?.reportable == true
            || line.reportFields(room: selection.room, reason: .other) != nil
          {
            NavigationLink("举报这条留言") { DeferredPage { LiveReportForm(selection: selection, owner: owner) } }
          }
        } else if accounts.state.active == nil {
          NavigationLink("登录后参与互动") { DeferredPage { QRLoginView() } }
        }
        if let issue { Text(issue) }
      }.disabled(busy).navigationTitle("留言操作").toolbar { Button("关闭") { dismiss() } }
        .confirmationDialog("屏蔽后将不再显示这位用户的直播弹幕", isPresented: $confirm) {
          Button("屏蔽这位用户", role: .destructive) {
            guard let owner, let uid = line.uid, line.room == selection.room else { return }
            busy = true
            Task {
              defer { busy = false }
              do {
                try await BiliAPI.shared.changeLiveShield(
                  room: selection.room, sender: uid, adding: true, owner: owner)
                guard owner == accounts.state.active else { return }
                shield = (shield ?? LiveShield(keyword_list: nil, shield_user_list: nil)).adding(
                  uid, name: line.name)
                dismiss()
              } catch { issue = error.localizedDescription }
            }
          }
          Button("取消", role: .cancel) {}
        }
  }
}
private struct LiveReportForm: View {
  let selection: LiveActionSelection, owner: String
  @EnvironmentObject private var accounts: AccountContext
  @State private var reason: LiveReportReason = .illegal
  @State private var busy = false
  @State private var result: String?
  @State private var done = false
  var body: some View {
    Form {
      Text(selection.line.text)
      Picker("举报原因", selection: $reason) {
        ForEach(LiveReportReason.allCases, id: \.rawValue) { Text($0.label).tag($0) }
      }.disabled(busy || done)
      Button("提交举报", role: .destructive) {
        guard !busy, !done, owner == accounts.state.active, selection.line.room == selection.room
        else { return }
        let fields: [String: String]?
        let path: String
        if let paid = selection.paid {
          guard paid.id == selection.line.paidID, paid.uid == selection.line.uid else { return }
          path = "/av/v1/SuperChat/report"
          fields = paid.reportFields(room: selection.room, label: reason.label)
        } else {
          path = "/xlive/web-ucenter/v1/dMReport/Report"
          fields = selection.line.reportFields(room: selection.room, reason: reason)
        }
        guard let fields else {
          result = "此留言无法举报"
          return
        }
        busy = true
        Task {
          defer { busy = false }
          do {
            try await BiliAPI.shared.submit(path, fields, expectedAccount: owner, service: .live)
            done = true
            result = "举报已提交"
          } catch { result = error.localizedDescription }
        }
      }.disabled(busy || done || owner != accounts.state.active)
      if let result { Text(result) }
    }.navigationTitle(selection.paid == nil ? "举报弹幕" : "举报醒目留言")
  }
}
struct LiveLikeButton: View {
  let room: LiveRoomIdentity, owner: String?
  @State private var counts = LiveLikeCounter()
  @State private var timer: Task<Void, Never>?
  @State private var note: String?
  @State private var accepted = false
  var body: some View {
    Button {
      guard let owner else {
        note = "请先登录观看账号"
        return
      }
      timer?.cancel()
      counts.tap()
      accepted = false
      timer = Task {
        do {
          try await Task.sleep(for: .milliseconds(800))
          try Task.checkCancellation()
        } catch { return }
        let taps = counts.take()
        timer = nil
        do {
          try await BiliAPI.shared.likeLive(room: room, taps: taps, owner: owner)
          accepted = true
        } catch { if !Task.isCancelled { note = error.localizedDescription } }
      }
    } label: {
      Image(systemName: counts.taps > 0 || accepted ? "hand.thumbsup.fill" : "hand.thumbsup")
        .overlay(alignment: .topTrailing) {
          if counts.taps > 1 { Text(String(counts.taps)).font(.caption2).offset(x: 6, y: -6) }
        }
    }.accessibilityLabel("为直播点赞").accessibilityValue(accepted ? "已点赞" : "")
      .onDisappear {
        timer?.cancel()
        timer = nil
        _ = counts.take()
      }
      .alert("直播点赞", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) {
        Button("好") {}
      } message: {
        Text(note ?? "")
      }
  }
}
