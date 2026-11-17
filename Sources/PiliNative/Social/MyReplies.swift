import PiliWire
import SwiftUI
import UniformTypeIdentifiers

struct ReplyFile: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  let data: Data
  init(_ data: Data) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    guard let d = configuration.file.regularFileContents else { throw ServiceError("不是有效的评论备份") }
    data = d
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    .init(regularFileWithContents: data)
  }
}
struct MyReplies: View {
  let uid: String
  @EnvironmentObject private var accounts: AccountContext
  @State private var checking: VisibilityRequest?
  @State private var removingCloud: SavedReply?
  @State private var changing = false
  @State private var items: [SavedReply] = []
  @State private var query = ""
  @State private var issue: String?
  @State private var file: ReplyFile?
  @State private var exporting = false
  @State private var importing = false
  @State private var revision = 0
  @State private var clearing = false
  @State private var removal: SavedReply?
  @AppStorage("reply.save") private var recording = true
  @State private var route: Route?
  private enum Route: Hashable {
    case link(SharedLink), article(Int64), dynamic(String, album: Bool), poster(Int64)
  }
  var body: some View {
    personalList
      .fileExporter(
        isPresented: $exporting, document: file, contentType: .json, defaultFilename: "我的评论"
      ) { if case .failure(let e) = $0 { issue = e.localizedDescription } }
      .fileImporter(
        isPresented: $importing, allowedContentTypes: [.json], onCompletion: receiveFile
      )
      .confirmationDialog("清空这个账号在本机保存的所有评论？", isPresented: $clearing) {
        Button("清空本地记录", role: .destructive) {
          Task {
            do {
              guard accounts.state.active == uid else { return }
              try await ReplyArchive.shared.clear(uid)
              revision += 1
            } catch { issue = error.localizedDescription }
          }
        }
      }
      .confirmationDialog(
        "从本机移除这条记录？",
        isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
        presenting: removal
      ) { row in
        Button("移除记录", role: .destructive) {
          Task {
            do {
              guard accounts.state.active == uid else { return }
              try await ReplyArchive.shared.remove(row.id, uid: uid)
              revision += 1
            } catch { issue = error.localizedDescription }
          }
        }
      }
      .alert("我的评论", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
        Button("好") {}
      } message: {
        Text(issue ?? "")
      }
      .task(id: revision) {
        do {
          guard accounts.state.active == uid else { return }
          let rows = try await ReplyArchive.shared.items(uid)
          guard accounts.state.active == uid else { return }
          items = rows
        } catch {
          issue = error.localizedDescription
        }
      }
  }
  private var personalList: some View {
    List {
      Section {
        Toggle("在本机保存我发表的评论", isOn: $recording)
      } footer: {
        Text("只记录在本机发表的评论，可导出备份或合并。")
      }
      if items.isEmpty {
        ContentUnavailableView("暂无本地评论", systemImage: "text.bubble")
          .listRowBackground(Color.clear)
      }
      Section {
        ForEach(items.filter { query.isEmpty || $0.body.localizedStandardContains(query) }) { r in
          rowView(r)
        }
      }
    }
    .environment(\.inListRows, true)
    .navigationDestination(item: $route) { r in
      switch r {
      case .link(let item): LinkDestination(item: item)
      case .article(let id): ArticleReader(id: id)
      case .dynamic(let id, let album): DynamicDetail(id: id, byAlbum: album)
      case .poster(let id):
        if let row = items.first(where: { $0.id == id }), let bytes = row.archivedProto,
          let wire = try? ReplyGateway.archived(bytes)
        {
          let reply = Reply(wire)
          SharePoster(
            content: .comment(
              oid: row.oid, type: row.type,
              root: reply.threadRoot == reply.id ? nil : reply.threadRoot, reply: reply))
        }
      }
    }
    .refreshable { revision += 1 }.disabled(changing || accounts.state.active != uid)
      .piliSheet(item: $checking) { value in VisibilityPanel(request: value) }
      .confirmationDialog(
        "删除这条已发表的评论？",
        isPresented: .init(get: { removingCloud != nil }, set: { if !$0 { removingCloud = nil } }),
        presenting: removingCloud
      ) { r in Button("删除云端评论", role: .destructive) { Task { await removePublished(r) } } }
      .onChange(of: accounts.state.active) { _, v in
        if v != uid {
          items = []
          checking = nil
          removingCloud = nil
          removal = nil
          file = nil
          exporting = false
          importing = false
          clearing = false
          query = ""
        }
      }
      .navigationTitle("我的评论").searchable(text: $query, prompt: "搜索已保存的评论")
      .toolbar {
        Menu {
          Button("清空本地记录", role: .destructive) { clearing = true }.disabled(items.isEmpty)
          Button("导出文件") {
            Task {
              do {
                guard accounts.state.active == uid else { return }
                let bytes = try await ReplyArchive.shared.export(uid)
                guard accounts.state.active == uid else { return }
                file = ReplyFile(bytes)
                exporting = true
              } catch { issue = error.localizedDescription }
            }
          }
          Button("复制备份") {
            Task {
              do {
                guard accounts.state.active == uid else { return }
                let bytes = try await ReplyArchive.shared.export(uid)
                guard accounts.state.active == uid else { return }
                UIPasteboard.general.string = String(decoding: bytes, as: UTF8.self)
              } catch { issue = error.localizedDescription }
            }
          }
          Button("从文件合并") { importing = true }
          Button("从剪贴板合并") {
            if let text = UIPasteboard.general.string { Task { await merge(Data(text.utf8)) } }
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      }
  }
  private func receiveFile(_ result: Result<URL, Error>) {
    do {
      guard accounts.state.active == uid else { return }
      let url = try result.get()
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
      guard size <= 32 * 1024 * 1024 else { throw ServiceError("文件过大") }
      let d = try Data(contentsOf: url)
      Task { await merge(d) }
    } catch { issue = error.localizedDescription }
  }
  private func rowView(_ r: SavedReply) -> some View {
    PlainRowLink {
      Discussion(
        oid: r.oid, type: r.type, root: (r.root ?? 0) > 0 ? r.root : r.id, owner: nil,
        anchor: (r.root ?? 0) > 0 ? r.id : nil)
    } label: {
      VStack(alignment: .leading, spacing: 6) {
        if let bytes = r.archivedProto, let wire = try? ReplyGateway.archived(bytes) {
          let reply = Reply(wire)
          if wire.hasMember || wire.hasMemberV2 { ReplyAuthorLabel(member: reply.member) }
          ReplyRichText(content: reply.content, maxLines: 4)
          if let items = reply.content.pictures, !items.isEmpty { ReplyPictures(items: items) }
        } else {
          Text(r.body).lineLimit(4)
        }
        if !r.pictures.isEmpty { Label("\(r.pictures.count) 张图片", systemImage: "photo") }
        Text(
          Date(timeIntervalSince1970: r.date),
          format: .dateTime.year().month().day().hour().minute()
        ).piliFont(.caption).foregroundStyle(.secondary)
      }
    }.swipeActions { Button("移除记录", role: .destructive) { removal = r } }
      .contextMenu {
        if r.type == 1 {
          Button("打开视频", systemImage: "play.rectangle") { route = .link(.archive(r.oid, 1)) }
        } else if r.type == 12 {
          Button("打开专栏", systemImage: "doc.text") { route = .article(r.oid) }
        }
        if r.archivedProto != nil {
          Button("保存或分享评论", systemImage: "square.and.arrow.up") { route = .poster(r.id) }
        }
        if let owner = storedOwner(r), owner == uid {
          Button("检查公开可见性") {
            checking = .init(
              .reply(oid: r.oid, kind: r.type, root: (r.root ?? 0) > 0 ? r.root! : r.id, id: r.id),
              user: uid)
          }
          Button("删除云端评论", role: .destructive) { removingCloud = r }
        }
        if r.type == 33 { Button("打开课时", systemImage: "graduationcap") { route = .link(.course(r.oid, true)) } }
        if r.type == 17 { Button("打开动态", systemImage: "text.bubble") { route = .dynamic(String(r.oid), album: false) } }
        if r.type == 11 {
          Button("打开图文动态", systemImage: "photo.on.rectangle") { route = .dynamic(String(r.oid), album: true) }
        }
        Button("复制评论", systemImage: "doc.on.doc") { UIPasteboard.general.string = r.body }
      }
  }
  private func storedOwner(_ r: SavedReply) -> String? {
    if let d = r.archivedProto, let row = try? ReplyGateway.archived(d), row.mid > 0 {
      return String(row.mid)
    }
    return nil
  }
  @MainActor private func removePublished(_ r: SavedReply) async {
    guard !changing, accounts.state.active == uid, storedOwner(r) == uid else { return }
    changing = true
    defer { changing = false }
    do {
      let root = (r.root ?? 0) > 0 ? r.root! : r.id
      let read = try await BiliAPI.shared.commentService(for: uid).list(
        oid: r.oid, type: Int64(r.type), thread: .detail(root: root, anchor: r.id), newest: false)
      guard
        read.rows.contains(where: {
          $0.id == r.id && $0.oid == r.oid && $0.type == Int64(r.type) && String($0.mid) == uid
        }), accounts.state.active == uid
      else { throw ServiceError("未能确认这条评论属于当前账号") }
      try await BiliAPI.shared.submit(
        "/x/v2/reply/del", ["oid": String(r.oid), "type": String(r.type), "rpid": String(r.id)],
        expectedAccount: uid)
      try await ReplyArchive.shared.remove(r.id, uid: uid)
      revision += 1
    } catch { if accounts.state.active == uid { issue = error.localizedDescription } }
  }
  private func merge(_ data: Data) async {
    guard accounts.state.active == uid else { return }
    do {
      try await ReplyArchive.shared.importData(data, uid: uid)
      revision += 1
    } catch { issue = error.localizedDescription }
  }
}
