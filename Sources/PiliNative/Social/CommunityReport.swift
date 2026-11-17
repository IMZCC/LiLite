import SwiftUI

enum ReportSubject {
  case comment(oid: Int64, type: Int, id: Int64, author: Int64?)
  case moment(id: String, author: Int64)
  case person(id: Int64)
  var author: Int64? {
    switch self {
    case .comment(_, _, _, let id): id
    case .moment(_, let id), .person(let id): id
    }
  }
  var title: String {
    switch self {
    case .comment: "举报评论"
    case .moment: "举报动态"
    case .person: "举报用户"
    }
  }
  var profile: Bool {
    if case .person = self { return true }
    return false
  }
  var comment: Bool {
    if case .comment = self { return true }
    return false
  }
  var web: URL? {
    switch self {
    case .comment(let oid, let type, let id, _):
      URL(
        string:
          "https://www.bilibili.com/h5/comment/report?oid=\(oid)&pageType=\(type)&rpid=\(id)&platform=ios"
      )
    case .person(let id):
      URL(string: "https://account.bilibili.com/h5/account-h5/gr/report?navhide=1&targetmid=\(id)")
    case .moment: nil
    }
  }
}
private struct ReportReason: Identifiable {
  let id: Int, label: String
  init(_ id: Int, _ label: String) {
    self.id = id
    self.label = label
  }
  static let comments: [(String, [Self])] = [
    (
      "违反法律法规",
      [.init(9, "违法违规"), .init(2, "色情"), .init(10, "低俗"), .init(12, "赌博诈骗"), .init(23, "违法信息外链")]
    ),
    ("不实信息", [.init(19, "涉政谣言"), .init(22, "虚假不实信息"), .init(20, "涉社会事件谣言")]),
    ("侵犯个人权益", [.init(7, "人身攻击"), .init(15, "侵犯隐私")]),
    (
      "有害社区环境",
      [
        .init(1, "垃圾广告"), .init(4, "引战"), .init(5, "剧透"), .init(3, "刷屏"), .init(8, "视频不相关"),
        .init(18, "违规抽奖"), .init(17, "青少年不良信息"),
      ]
    ),
    ("其他", [.init(0, "其他")]),
  ]
  static let moments: [Self] = [
    .init(4, "垃圾广告"), .init(8, "引战"), .init(1, "色情"), .init(5, "人身攻击"), .init(3, "违法信息"),
    .init(9, "涉政谣言"), .init(10, "涉社会事件谣言"), .init(12, "虚假不实信息"), .init(13, "违法信息外链"),
    .init(0, "其他"),
  ]
  static let profileItems = ["头像", "昵称", "签名"],
    profileReasons = ["色情低俗", "不实信息", "违禁", "人身攻击", "赌博诈骗", "违规引流外链"]
}

struct CommunityReport: View {
  let target: ReportSubject, uid: String
  var onHide: () -> Void = {}
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var accounts: AccountContext
  @State private var reason: Int?
  @State private var items = Set<Int>()
  @State private var details = ""
  @State private var block = false
  @State private var busy = false
  @State private var submitted = false
  @State private var retryBlock = false
  @State private var hideAfter = false
  @State private var error: String?
  private var showDetails: Bool {
    !target.profile && reason != nil && (target.comment || reason == 0)
  }
  private var needsDetails: Bool {
    !target.profile && (reason == 0 || (target.comment && reason == 22))
  }
  private var allowed: Bool {
    accounts.state.active == uid && (target.profile ? !items.isEmpty : reason != nil)
      && (!needsDetails || !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }
  var body: some View {
    Form {
      if submitted {
        Label("举报已提交", systemImage: "checkmark.circle")
        if retryBlock {
          Button("重试加入黑名单") { Task { await finishBlock() } }.disabled(
            busy || accounts.state.active != uid)
        }
        Button("完成") {
          dismiss()
          if hideAfter { onHide() }
        }
      } else {
        if target.profile {
          Section("举报内容") {
            ForEach(Array(ReportReason.profileItems.enumerated()), id: \.offset) { i, label in
              Toggle(
                label,
                isOn: Binding(
                  get: { items.contains(i + 1) },
                  set: { value in
                    if value { items.insert(i + 1) } else { items.remove(i + 1) }
                  }))
            }
          }
        }
        Section("举报原因") {
          Picker("原因", selection: $reason) {
            Text(target.profile ? "不填写" : "请选择").tag(nil as Int?)
            if target.profile {
              ForEach(Array(ReportReason.profileReasons.enumerated()), id: \.offset) { i, label in
                Text(label).tag(Optional(i + 1))
              }
            } else if target.comment {
              ForEach(ReportReason.comments, id: \.0) { section in
                Section(section.0) { ForEach(section.1) { r in Text(r.label).tag(Optional(r.id)) } }
              }
            } else {
              ForEach(ReportReason.moments) { r in Text(r.label).tag(Optional(r.id)) }
            }
          }
          if showDetails {
            TextField(needsDetails ? "请填写说明" : "补充说明（选填）", text: $details, axis: .vertical)
          }
          if !target.profile, let mid = target.author, String(mid) != uid {
            Toggle("同时加入黑名单", isOn: $block)
          }
        }
        Button("提交举报", role: .destructive) { Task { await submit() } }.disabled(!allowed || busy)
        if let web = target.web { NavigationLink("网页举报") { SitePage(url: web) } }
        if !target.profile, let mid = target.author, String(mid) != uid {
          LocalMute(mid: mid) {
            dismiss()
            onHide()
          }
        }
      }
      if let error { Text(error).foregroundStyle(.secondary) }
    }.navigationTitle(target.title).disabled(busy)
  }
  @MainActor private func submit() async {
    guard allowed, !busy, !submitted else { return }
    busy = true
    error = nil
    defer { busy = false }
    do {
      let api = BiliAPI.shared
      let note = details.trimmingCharacters(in: .whitespacesAndNewlines)
      switch target {
      case .person(let id):
        var f = [
          "mid": String(id), "reason": items.sorted().map(String.init).joined(separator: ","),
        ]
        if let reason { f["reason_v2"] = String(reason) }
        try await api.submit("/ajax/report/add", f, expectedAccount: uid, service: .space)
      case .comment(let oid, let type, let id, _):
        guard let reason else { return }
        var f = [
          "oid": String(oid), "type": String(type), "rpid": String(id), "reason": String(reason),
          "add_blacklist": block ? "true" : "false", "scene": "main", "gaia_source": "main_h5",
          "platform": "ios",
        ]
        if !note.isEmpty { f["content"] = note }
        try await api.submit("/x/v2/reply/report", f, expectedAccount: uid)
        hideAfter = true
      case .moment(let id, let mid):
        guard let reason else { return }
        var f = ["accused_uid": String(mid), "dynamic_id": id, "reason_type": String(reason)]
        if showDetails && !note.isEmpty { f["reason_desc"] = note }
        try await api.submit("/x/dynamic/feed/dynamic_report/add", f, expectedAccount: uid)
      }
      submitted = true
      if case .moment = target, block { await blockAuthor() }
    } catch { self.error = error.localizedDescription }
  }
  @MainActor private func finishBlock() async {
    guard !busy, submitted, retryBlock else { return }
    busy = true
    defer { busy = false }
    await blockAuthor()
  }
  @MainActor private func blockAuthor() async {
    guard let mid = target.author else { return }
    do {
      try await BiliAPI.shared.submit(
        "/x/relation/modify", ["fid": String(mid), "act": "5", "re_src": "11"], expectedAccount: uid
      )
      retryBlock = false
      error = nil
      hideAfter = true
    } catch {
      retryBlock = true
      self.error = "加入黑名单失败：" + error.localizedDescription
    }
  }
}

struct LocalMute: View {
  let mid: Int64
  var changed: () -> Void = {}
  @State private var confirming = false
  @State private var issue: String?
  var body: some View {
    Button(role: .destructive) {
      confirming = true
    } label: {
      Label("在本机屏蔽此用户", systemImage: "person.crop.circle.badge.minus")
    }
    .confirmationDialog("在本机屏蔽此用户？", isPresented: $confirming, titleVisibility: .visible) {
      Button("屏蔽", role: .destructive) {
        do {
          var rules = RecommendationRules.current()
          rules.blockedCreators.insert(mid)
          try rules.save()
          changed()
        } catch { issue = error.localizedDescription }
      }
    }.alert("无法保存", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
      Button("好") {}
    } message: {
      Text(issue ?? "")
    }
  }
}
