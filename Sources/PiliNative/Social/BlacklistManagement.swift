import SwiftUI
import UniformTypeIdentifiers

struct BlacklistView: View {
  let uid: String
  @EnvironmentObject private var accounts: AccountContext
  @State private var local = true
  var body: some View {
    VStack(spacing: 0) {
      ChipBar(items: [true, false], selection: $local, title: { $0 ? "本机" : "在线" }).padding(.vertical, 6)
      if local { LocalCreatorBlockList() }
      else if !uid.isEmpty, accounts.state.active == uid { OnlineCreatorBlockList(uid: uid).id(uid) }
      else { ContentUnavailableView("登录后查看在线黑名单", systemImage: "person.crop.circle") }
    }.navigationTitle("黑名单管理")
  }
}
struct LocalCreatorBlockList: View {
  @AppStorage(RecommendationRules.key) private var stored = Data()
  @State private var input = ""
  @State private var manual = ""
  @State private var message: String?
  @State private var removing: Int64?
  @State private var importing = false
  @State private var exporting = false
  @State private var typing = false
  @State private var incoming: Set<Int64>?
  @State private var output: BlockListDocument?
  private var ids: Set<Int64> {
    (try? JSONDecoder().decode(RecommendationRules.self, from: stored))?.blockedCreators ?? []
  }
  var body: some View {
    List {
      Section {
        HStack {
          TextField("输入 UID", text: $input).keyboardType(.numberPad)
          Button("添加") {
            if let n = Int64(input), n > 0 { commit([n]); input = "" }
          }.disabled(Int64(input).map { $0 > 0 } != true)
        }
        Menu("导入与导出") {
          Button("导出 JSON 文件") { do { output = try .init(ids); exporting = true } catch { message = error.localizedDescription } }
          Button("复制 JSON") { do { UIPasteboard.general.string = String(decoding: try LocalCreatorBlockFile.encode(ids), as: UTF8.self); message = "已复制" } catch { message = error.localizedDescription } }
          Button("从文件导入") { importing = true }
          Button("从剪贴板导入") { preview(Data((UIPasteboard.general.string ?? "").utf8)) }
          Button("手动输入 JSON") { manual = ""; typing = true }
        }
        if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
      }
      Section("已屏蔽 \(ids.count) 位用户") {
        ForEach(ids.sorted(), id: \.self) { id in
          PlainRowLink { CreatorSpace(mid: id, name: "用户空间") } label: {
            HStack(spacing: 12) {
              Image(systemName: "person.crop.circle.badge.xmark").font(.title2)
                .foregroundStyle(.secondary).frame(width: 40)
              Text("UID " + String(id)).font(.body.monospacedDigit())
              Spacer(minLength: 0)
            }.padding(.vertical, 2).contentShape(Rectangle())
          }
            .swipeActions(allowsFullSwipe: false) { Button("移除", role: .destructive) { removing = id } }
            .contextMenu { Button("移除", role: .destructive) { removing = id } }
        }
      }
    }
    .listStyle(.insetGrouped).environment(\.inListRows, true)
    .overlay {
      if ids.isEmpty {
        ContentUnavailableView("本机黑名单为空", systemImage: "hand.raised",
          description: Text("屏蔽的 UP 主不会出现在推荐和热门中"))
          .padding(.top, 160).allowsHitTesting(false)
      }
    }
      .fileExporter(isPresented: $exporting, document: output, contentType: .json, defaultFilename: "blackMids") { result in
        output = nil
        if case .failure(let e) = result { message = e.localizedDescription }
      }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText]) { result in
        do {
          let url = try result.get(), access = url.startAccessingSecurityScopedResource()
          defer { if access { url.stopAccessingSecurityScopedResource() } }
          guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= LocalCreatorBlockFile.limit else { throw ServiceError("文件过大") }
          preview(try Data(contentsOf: url))
        } catch { message = error.localizedDescription }
      }
      .piliSheet(isPresented: $typing) {
        PiliNavigationStack {
          Form { TextEditor(text: $manual).autocorrectionDisabled().textInputAutocapitalization(.never).frame(minHeight: 160) }
            .navigationTitle("输入黑名单 JSON").toolbar {
              Button("取消") { typing = false }
              Button("预览") { typing = false; let data = Data(manual.utf8); manual = ""; preview(data) }.disabled(manual.isEmpty)
            }
        }
      }
      .confirmationDialog("合并到本机黑名单？", isPresented: Binding(get: { incoming != nil }, set: { if !$0 { incoming = nil } }), presenting: incoming) { entries in
        Button("合并") { commit(entries) }
      } message: { entries in Text("将新增 \(entries.subtracting(ids).count) 位，保留已有的用户") }
      .confirmationDialog("从本机黑名单移除？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { id in
        Button("移除", role: .destructive) {
          do { var r = RecommendationRules.current(); r.blockedCreators.remove(id); try r.save() }
          catch { message = error.localizedDescription }
        }
      }
  }
  private func preview(_ data: Data) {
    do { incoming = try LocalCreatorBlockFile.decode(data) }
    catch { message = error.localizedDescription }
  }
  private func commit(_ mids: Set<Int64>) {
    do { let count = try LocalCreatorBlockFile.merge(mids); message = count == 0 ? "没有新增用户" : "已添加 \(count) 位用户" }
    catch { message = error.localizedDescription }
  }
}
private struct BlockListDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  let data: Data
  init(_ ids: Set<Int64>) throws { data = try LocalCreatorBlockFile.encode(ids) }
  init(configuration: ReadConfiguration) throws {
    guard let d = configuration.file.regularFileContents, d.count <= LocalCreatorBlockFile.limit else { throw ServiceError("文件过大") }
    data = d
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: data) }
}
private struct OnlineCreatorBlockList: View {
  let uid: String
  struct Blacklist: Decodable { let list: [Creator]?, total: Int? }
  @State private var revision = 0
  @State private var busy = false
  @State private var issue: String?
  @State private var removing: Creator?
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    PageList(empty: "黑名单为空", autoMore: true) { cursor in
      let n = Int(cursor ?? "1") ?? 1
      let r = try await BiliAPI.shared.read("/x/relation/blacks", ["pn": String(n), "ps": "20"], expectedAccount: uid, as: Blacklist.self)
      try Task.checkCancellation()
      guard accounts.state.active == uid else { throw CancellationError() }
      let rows = r.list ?? []
      if !rows.isEmpty { _ = try LocalCreatorBlockFile.merge(Set(rows.map(\.mid).filter { $0 > 0 })) }
      return Page(items: rows, next: !rows.isEmpty && n * 20 < (r.total ?? 0) ? String(n + 1) : nil)
    } row: { user in
      VStack(alignment: .leading, spacing: 4) {
        CreatorLink(person: user)
        if let added = MediaStats.published(user.mtime) {
          Text("拉黑于 " + added).font(.caption).foregroundStyle(.secondary).padding(.leading, 56)
        }
      }.swipeActions(allowsFullSwipe: false) { Button("移出黑名单", role: .destructive) { removing = user } }
        .contextMenu { Button("移出黑名单", role: .destructive) { removing = user } }
    }.id(revision).disabled(busy)
      .confirmationDialog("移出在线黑名单？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { user in
        Button("移除 " + (user.uname ?? String(user.mid)), role: .destructive) { Task { await remove(user) } }
      }
      .alert("黑名单", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) { Button("好") {} } message: { Text(issue ?? "") }
  }
  private func remove(_ user: Creator) async {
    guard !busy, uid == accounts.state.active else { return }
    busy = true; defer { busy = false }
    do {
      try await BiliAPI.shared.submit("/x/relation/modify", ["fid": String(user.mid), "act": "6", "re_src": "11"], expectedAccount: uid)
      guard uid == accounts.state.active else { return }
      var local = RecommendationRules.current()
      local.blockedCreators.remove(user.mid); try local.save()
      revision += 1
    } catch { if uid == accounts.state.active { issue = error.localizedDescription } }
  }
}
