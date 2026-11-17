import PhotosUI
import SwiftUI

struct NewVote: View {
  var existing: VoteRef?
  let selected: (VoteRef) -> Void
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var accounts: AccountContext
  @State private var owner: String?
  @State private var title = ""
  @State private var intro = ""
  @State private var imageMode = false
  @State private var options = [DraftOption(), DraftOption()]
  @State private var maxChoices = 1
  @State private var until = Date().addingTimeInterval(86400)
  @State private var ready = false
  @State private var busy = false
  @State private var retry = 0
  @State private var issue: String?
  private struct DraftOption: Identifiable {
    let id = UUID()
    var text = "", image = ""
    var chosen: PhotosPickerItem?
  }
  private var valid: Bool {
    guard ready, owner != nil, owner == accounts.state.active, (1...32).contains(title.count), intro.count <= 100,
      (2...20).contains(options.count), until > .now, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    return options.allSatisfy {
      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text.count <= 20
        && (!imageMode || $0.chosen != nil || !$0.image.isEmpty)
    }
  }
  var body: some View {
    Form {
      if !ready && issue == nil { ProgressView() }
      if ready {
        Section {
          TextField("投票标题（最多 32 字）", text: $title)
          TextField("说明（最多 100 字）", text: $intro, axis: .vertical)
          Picker("选项类型", selection: $imageMode) {
            Text("文字").tag(false); Text("图片").tag(true)
          }.pickerStyle(.segmented)
        }
        Section("选项") {
          ForEach($options) { $option in
            VStack(alignment: .leading) {
              TextField("选项（最多 20 字）", text: $option.text)
              if imageMode {
                HStack {
                  if option.chosen == nil, let url = GalleryPicture.source(option.image) {
                    SiteThumbnail(url: url) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                      .frame(width: 46, height: 46)
                  }
                  PhotosPicker(selection: $option.chosen, matching: .images) {
                    Label(option.chosen != nil ? "已选图片，重新选择" : option.image.isEmpty ? "选择图片" : "更换图片", systemImage: "photo")
                  }
                }
              }
            }
          }.onDelete { indexes in
            guard options.count - indexes.count >= 2 else { return }
            options.remove(atOffsets: indexes); maxChoices = min(maxChoices, options.count)
          }.onMove { options.move(fromOffsets: $0, toOffset: $1) }
          if options.count < 20 { Button("添加选项") { options.append(.init()) } }
        }
        Stepper("最多选择 \(maxChoices) 项", value: $maxChoices, in: 1...max(1, options.count))
        DatePicker("截止时间", selection: $until, in: Date()...Date().addingTimeInterval(90 * 86400))
      }
      if let issue {
        Text(issue).foregroundStyle(.secondary)
        if !ready, existing != nil { Button("重新读取") { retry += 1 } }
      }
    }.navigationTitle(existing == nil ? "发起投票" : "编辑投票").toolbar {
      Button(existing == nil ? "创建投票" : "保存") { Task { await save() } }
        .disabled(busy || !valid)
    }.disabled(busy).interactiveDismissDisabled(busy)
      .task(id: retry) { await prepare() }
      .onChange(of: accounts.state.active) { _, id in if let owner, id != owner { dismiss() } }
  }
  private func prepare() async {
    issue = nil
    guard let uid = accounts.state.active else { issue = "请先登录"; return }
    owner = uid
    guard let existing else { ready = true; return }
    do {
      let response = try await BiliAPI.shared.read("/x/vote/vote_info", ["vote_id": String(existing.id)], expectedAccount: uid, as: VoteView.Envelope.self)
      let v = response.vote_info
      guard v.vote_publisher == Int64(uid) else { throw ServiceError("只能编辑自己发起的投票") }
      let rows = v.options ?? []
      guard (2...20).contains(rows.count), let end = v.end_time else { throw ServiceError("投票信息不完整") }
      guard end > Int64(Date().timeIntervalSince1970) else { throw ServiceError("投票已结束") }
      try Task.checkCancellation()
      title = v.title ?? ""; intro = v.desc ?? ""
      imageMode = v.type == 1 || rows.contains { $0.img_url?.isEmpty == false }
      options = rows.map { DraftOption(text: $0.opt_desc ?? "", image: $0.img_url ?? "") }
      maxChoices = min(rows.count, max(1, v.choice_cnt ?? 1))
      until = Date(timeIntervalSince1970: Double(end)); ready = true
    } catch { if !Task.isCancelled { issue = error.localizedDescription } }
  }
  private func save() async {
    guard !busy, valid, let owner else { return }
    busy = true; issue = nil
    defer { busy = false }
    do {
      guard let user = try await AccountJar.shared.current(), user.id == owner, let mid = Int64(owner) else { throw ServiceError("账号已切换") }
      var encoded = [[String: String]]()
      for index in options.indices {
        if imageMode, let item = options[index].chosen {
          guard let raw = try await item.loadTransferable(type: Data.self), raw.count <= 64 * 1024 * 1024,
            let image = UIImage(data: raw), let jpeg = image.jpegData(compressionQuality: 0.85),
            jpeg.count <= 16 * 1024 * 1024 else { throw ServiceError("无法读取选项图片，或图片过大") }
          guard try await AccountJar.shared.current()?.id == owner else { throw ServiceError("账号已切换") }
          let uploaded = try await BiliAPI.shared.upload(jpeg, account: user, biz: "vote")
          options[index].image = uploaded.image_url; options[index].chosen = nil
        }
        encoded.append(["opt_desc": options[index].text, "img_url": imageMode ? options[index].image : ""])
      }
      let duration = Int(until.timeIntervalSinceNow)
      guard (1...(90 * 86400)).contains(duration) else { throw ServiceError("请选择未来 90 天内的截止时间") }
      var fields: [String: Any] = ["title": title, "desc": intro, "type": imageMode ? 1 : 0, "choice_cnt": maxChoices,
        "duration": duration, "options": encoded, "only_fans_level": 0, "vote_publisher": mid]
      if let existing { fields["vote_id"] = existing.id }
      let reply = try await BiliAPI.shared.dynPost(existing == nil ? "/x/vote/create" : "/x/vote/update", ["vote_info": fields], expectedAccount: owner)
      guard let id = (reply["vote_id"] as? NSNumber)?.int64Value ?? (reply["vote_id"] as? String).flatMap(Int64.init),
        id > 0, existing.map({ $0.id == id }) ?? true else { throw ServiceError("未取得有效投票编号") }
      guard accounts.state.active == owner else { return }
      selected(.init(id: id, title: title)); dismiss()
    } catch { if accounts.state.active == owner { issue = error.localizedDescription } }
  }
}
