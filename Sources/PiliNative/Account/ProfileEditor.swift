import PhotosUI
import SwiftUI

struct EditableProfile: Decodable {
  let mid: Int64, uname: String, sign: String, sex: String, birthday: String
  let face: String?
  enum Field: String, CaseIterable, Identifiable {
    case nickname = "昵称"
    case bio = "个性签名"
    case gender = "性别"
    case birth = "出生日期"
    var id: String { rawValue }
  }
  func value(_ f: Field) -> String {
    switch f {
    case .nickname: uname
    case .bio: sign
    case .gender: sex
    case .birth: birthday
    }
  }
}
extension BiliAPI {
  func editableProfile(_ uid: String) async throws -> EditableProfile {
    let p = try await read(
      "/x/member/web/account", [:], expectedAccount: uid, as: EditableProfile.self)
    guard String(p.mid) == uid else { throw ServiceError("账号已切换") }
    return p
  }
  struct RenameTerms: Decodable {
    let allow: Bool, verified: Bool, summary: String
    enum CodingKeys: String, CodingKey {
      case allow
      case verified = "realname_or_tel"
      case summary = "confirm_message"
    }
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      func flag(_ k: CodingKeys) throws -> Bool {
        if let b = try? c.decode(Bool.self, forKey: k) { return b }
        return try c.decode(Int.self, forKey: k) != 0
      }
      allow = try flag(.allow)
      verified = try flag(.verified)
      summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
    }
  }
  func renameTerms(_ uid: String) async throws -> RenameTerms {
    try await read(
      "/x/member/uname/update/message", [:], expectedAccount: uid, as: RenameTerms.self)
  }
  func editProfile(
    _ uid: String, field: EditableProfile.Field, original: String, value: String, consent: String?
  ) async throws {
    let latest = try await editableProfile(uid)
    guard latest.value(field) == original else { throw ServiceError("这项资料已经变更，请重新打开后编辑") }
    var values = [
      "uname": latest.uname, "usersign": latest.sign, "sex": latest.sex,
      "birthday": latest.birthday, "source": "profile_web",
    ]
    switch field {
    case .nickname:
      let terms = try await renameTerms(uid)
      guard terms.allow, terms.verified, !terms.summary.isEmpty, terms.summary == consent else {
        throw ServiceError("改名条件已变更，请重新查看")
      }
      guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 16 else {
        throw ServiceError("昵称须为 1 至 16 个字")
      }
      values["uname"] = value
    case .bio:
      guard value.count <= 70 else { throw ServiceError("个性签名最多 70 个字") }
      values["usersign"] = value
    case .gender:
      guard ["男", "女", "保密"].contains(value) else { throw ServiceError("请选择性别") }
      values["sex"] = value
    case .birth: values["birthday"] = value
    }
    let bytes = try await submitResponse("/x/member/web/update", values, expectedAccount: uid)
    if let envelope = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      let body = envelope["data"] as? [String: Any], let code = body["code"] as? Int, code != 0
    {
      let choices = (body["name_list"] as? [String])?.prefix(4).joined(separator: "、") ?? ""
      throw ServiceError(
        choices.isEmpty ? (body["message"] as? String ?? "资料修改未获接受") : "这个昵称不可用，可尝试：" + choices)
    }
  }
  func uploadAvatar(_ photo: Data, uid: String, animated: Bool) async throws {
    guard photo.count <= 5 * 1024 * 1024, let account = try await AccountJar.shared.current(),
      account.id == uid, let csrf = account.csrf
    else { throw ServiceError("无法更新头像") }
    var c = URLComponents()
    c.scheme = "https"
    c.host = "api.bilibili.com"
    c.path = "/x/member/web/face/update"
    c.queryItems = [.init(name: "csrf", value: csrf)]
    guard let u = c.url else { throw URLError(.badURL) }
    let boundary = "PiliNative-" + UUID().uuidString
    var body = Data()
    func add(_ s: String) { body.append(contentsOf: s.utf8) }
    for (key, value) in [("dopost", "save"), ("DisplayRank", "10000")] {
      add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
    }
    add(
      "--\(boundary)\r\nContent-Disposition: form-data; name=\"face\"; filename=\"avatar.\(animated ? "gif":"jpg")\"\r\nContent-Type: image/\(animated ? "gif":"jpeg")\r\n\r\n"
    )
    body.append(photo)
    add("\r\n--\(boundary)--\r\n")
    var q = URLRequest(url: u, timeoutInterval: 30)
    q.httpMethod = "POST"
    q.httpBody = body
    q.httpShouldHandleCookies = false
    q.setValue(account.header, forHTTPHeaderField: "Cookie")
    q.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
    q.setValue("https://account.bilibili.com/", forHTTPHeaderField: "Referer")
    let (data, raw) = try await webResponse(q, identity: account)
    struct Result: Decodable { let code: Int, message: String? }
    let result = try JSONDecoder().decode(Result.self, from: data)
    guard (raw as? HTTPURLResponse)?.statusCode == 200, result.code == 0 else {
      throw ServiceError(result.message ?? "头像未更新")
    }
  }
}

struct ProfileEditor: View {
  @EnvironmentObject private var accounts: AccountContext
  let uid: String
  var changed: () -> Void = {}
  @State private var info: EditableProfile?
  @State private var issue: String?
  @State private var epoch = 0
  @State private var field: EditableProfile.Field?
  @State private var savingGender = false
  var body: some View {
    List {
      if let info {
        Section {
          NavigationLink {
            AvatarEditor(uid: uid, changed: refresh)
          } label: {
            HStack {
              Text("头像")
              Spacer()
              ProfileAvatar(url: info.face.flatMap(httpsURL), size: 56)
            }
            .padding(.vertical, 4)
          }
          editRow(.nickname, info)
          Menu {
            Picker("性别", selection: Binding(get: { info.sex }, set: { saveGender($0, from: info.sex) })) {
              ForEach(["男", "保密", "女"], id: \.self) { Text($0).tag($0) }
            }
          } label: {
            ProfileValueRow(title: "性别", value: info.sex.isEmpty ? "未知" : info.sex, busy: savingGender)
          }
          .disabled(savingGender)
          editRow(.birth, info)
          editRow(.bio, info)
        }
        Section {
          NavigationLink {
            SitePage(url: URL(string: "https://www.bilibili.com/h5/mall/pendant/home")!)
          } label: { Text("头像挂件") }
        }
        Section {
          Button {
            UIPasteboard.general.string = uid
            AppToast.show("已复制 UID")
          } label: {
            HStack {
              Text("UID").foregroundStyle(.primary)
              Spacer()
              Text(uid).monospacedDigit().foregroundStyle(.secondary)
              Image(systemName: "doc.on.doc").font(.footnote).foregroundStyle(.tertiary)
            }
          }
        }
        Section {
          NavigationLink {
            SitePage(url: URL(string: "https://account.bilibili.com/official/mobile/home")!)
          } label: { Text("哔哩哔哩认证") }
        }
      } else if let issue {
        ContentUnavailableView {
          Label("资料未能载入", systemImage: "person.crop.circle.badge.exclamationmark")
        } description: { Text(issue) } actions: { Button("重试") { epoch += 1 } }
          .listRowBackground(Color.clear)
      } else {
        ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
      }
    }
    .listStyle(.insetGrouped).listSectionSpacing(16)
    .navigationTitle("编辑资料").navigationBarTitleDisplayMode(.inline)
    .task(id: "\(uid):\(accounts.state.active ?? ""):\(epoch)") {
      guard uid == accounts.state.active else { info = nil; field = nil; issue = "账号已切换"; return }
      do {
        let p = try await BiliAPI.shared.editableProfile(uid)
        try Task.checkCancellation()
        info = p
        issue = nil
      } catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }.piliSheet(item: $field) { f in
      if let info {
        PiliNavigationStack {
          ProfileFieldEditor(uid: uid, field: f, initial: info.value(f), changed: refresh)
        }
      }
    }
  }
  private func refresh() {
    epoch += 1
    changed()
  }
  private func editRow(_ f: EditableProfile.Field, _ info: EditableProfile) -> some View {
    let value = info.value(f)
    return Button { field = f } label: {
      ProfileValueRow(title: f == .birth ? "出生年月" : f.rawValue,
        value: value.isEmpty || value == "0000-00-00" ? "未填写" : value, chevron: true)
    }
  }
  private func saveGender(_ value: String, from original: String) {
    guard value != original, !savingGender else { return }
    savingGender = true
    Task {
      defer { savingGender = false }
      guard let finished = try? SleepExitFence.shared.enter() else { return }
      defer { finished() }
      do {
        try await BiliAPI.shared.editProfile(uid, field: .gender, original: original, value: value, consent: nil)
        AppToast.show("修改成功")
        refresh()
      } catch { AppToast.show(error.localizedDescription) }
    }
  }
}

/// "标题 ……… 值 ›" row of the profile editor (the original's ListTile with the value trailing).
private struct ProfileValueRow: View {
  let title: String
  let value: String
  var chevron = false
  var busy = false
  var body: some View {
    HStack(spacing: 12) {
      Text(title).foregroundStyle(.primary)
      Spacer(minLength: 16)
      if busy { ProgressView() }
      Text(value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
      Image(systemName: chevron ? "chevron.right" : "chevron.up.chevron.down")
        .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
    }
    .contentShape(Rectangle())
  }
}
private struct ProfileFieldEditor: View {
  let uid: String, field: EditableProfile.Field, initial: String, changed: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var draft = ""
  @State private var date = Date()
  @State private var terms: BiliAPI.RenameTerms?
  @State private var confirm = false
  @State private var busy = false
  @State private var issue: String?
  private let dateFormat: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()
  private var current: String { field == .birth ? dateFormat.string(from: date) : draft }
  private var canSave: Bool {
    guard current != initial, !busy else { return false }
    switch field {
    case .nickname:
      return !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && current.count <= 16
        && terms?.allow == true && terms?.verified == true && terms?.summary.isEmpty == false
    case .gender: return ["男", "女", "保密"].contains(current)
    case .bio: return current.count <= 70
    case .birth: return true
    }
  }
  var body: some View {
    Form {
      switch field {
      case .nickname:
        Section {
          TextField(initial, text: $draft).font(.body)
        } footer: {
          HStack(alignment: .top) {
            if let terms, !terms.summary.isEmpty { Text(terms.summary) }
            else if terms == nil, issue == nil { ProgressView().controlSize(.small) }
            Spacer()
            Text("\(draft.count)/16").monospacedDigit().foregroundStyle(draft.count > 16 ? .red : .secondary)
          }
        }
        if let terms, !terms.allow || !terms.verified { Section { official } }
      case .bio:
        Section {
          TextField(initial.isEmpty ? "介绍一下自己" : initial, text: $draft, axis: .vertical).lineLimit(4...6)
        } footer: {
          HStack {
            Spacer()
            Text("\(draft.count)/70").monospacedDigit().foregroundStyle(draft.count > 70 ? .red : .secondary)
          }
        }
      case .gender:
        Picker("性别", selection: $draft) {
          ForEach(["男", "保密", "女"], id: \.self) { Text($0).tag($0) }
        }.pickerStyle(.inline).labelsHidden()
      case .birth:
        DatePicker("出生年月", selection: $date, in: ...Date(), displayedComponents: .date)
          .datePickerStyle(.graphical)
      }
      if let issue {
        Section {
          Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.red)
          official
        }
      }
    }
    .navigationTitle("修改" + (field == .birth ? "出生年月" : field.rawValue))
    .navigationBarTitleDisplayMode(.inline)
    .presentationDetents(field == .birth ? [.large] : [.medium, .large])
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
      ToolbarItem(placement: .confirmationAction) {
        Button("保存") { if field == .nickname { confirm = true } else { Task { await save() } } }
          .disabled(!canSave)
      }
    }.interactiveDismissDisabled(busy).task {
      draft = initial
      date = dateFormat.date(from: initial) ?? Date()
      if field == .nickname {
        do { terms = try await BiliAPI.shared.renameTerms(uid) } catch {
          issue = error.localizedDescription
        }
      }
    }.confirmationDialog(terms?.summary ?? "修改昵称？", isPresented: $confirm) {
      Button("确认修改昵称") { Task { await save() } }
    }
  }
  private var official: some View {
    Link("前往哔哩哔哩账号中心", destination: URL(string: "https://account.bilibili.com/account/setting")!)
  }
  @MainActor private func save() async {
    guard let finished = try? SleepExitFence.shared.enter() else { return }; defer { finished() }
    guard canSave else { return }
    busy = true
    defer { busy = false }
    do {
      try await BiliAPI.shared.editProfile(
        uid, field: field, original: initial, value: current,
        consent: field == .nickname ? terms?.summary : nil)
      changed()
      dismiss()
    } catch { issue = error.localizedDescription }
  }
}
