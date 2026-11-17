import SwiftUI
import UniformTypeIdentifiers

struct LegacyCacheImportView: View {
  @EnvironmentObject private var accounts: AccountContext
  @State private var pick = false
  @State private var source: URL?
  @State private var list = [LegacyCacheCatalog.Item]()
  @State private var checked = Set<String>()
  @State private var result = [String: String]()
  @State private var skipped = 0
  @State private var busy = false
  @State private var preserve = false
  @State private var confirm = false
  @State private var issue: String?
  private var owner: String { accounts.state.owner(.role(.video)) ?? "" }
  var body: some View {
    List {
      Button("选择原版缓存目录") { pick = true }
      if let source { Text(source.lastPathComponent).font(.caption) }
      if let issue { Text(issue) }
      if skipped > 0 { Text("已跳过 \(skipped) 个无效条目").font(.caption) }
      if !list.isEmpty {
        Toggle("沿用原缓存音画质", isOn: $preserve)
        Button(checked.count == list.count ? "取消全选" : "全选") {
          checked = checked.count == list.count ? [] : Set(list.map(\.id))
        }
        ForEach(list) { v in
          Button {
            if !checked.insert(v.id).inserted { checked.remove(v.id) }
          } label: {
            VStack(alignment: .leading) {
              Label(
                v.title, systemImage: checked.contains(v.id) ? "checkmark.circle.fill" : "circle")
              Text(result[v.id] ?? (v.part + " · " + (v.complete ? "原缓存已完成" : "原缓存未完成"))).font(
                .caption
              ).foregroundStyle(.secondary)
            }
          }
        }
        Button("重新缓存所选 \(checked.count) 项") { confirm = true }.disabled(checked.isEmpty)
      }
    }.navigationTitle("恢复原版缓存清单").disabled(busy)
      .fileImporter(isPresented: $pick, allowedContentTypes: [.folder]) { res in
        do { source = try res.get() } catch {
          if (error as NSError).code != NSUserCancelledError { issue = error.localizedDescription }
        }
      }
      .task(id: source) {
        guard let source else { return }
        busy = true
        defer { busy = false }
        list = []
        checked = []
        result = [:]
        issue = nil
        do {
          let r = try await Self.read(source)
          try Task.checkCancellation()
          list = r.items
          skipped = r.skipped
          if list.isEmpty { issue = "没有找到原版缓存清单" }
        } catch { if !Task.isCancelled { issue = error.localizedDescription } }
      }
      .confirmationDialog("按当前账号重新缓存？", isPresented: $confirm, titleVisibility: .visible) {
        Button("开始") {
          let uid = owner
          Task { await restore(uid) }
        }
      }
      .onChange(of: owner) { _, _ in
        checked = []
        result = [:]
      }
  }
  private nonisolated static func read(_ url: URL) async throws -> LegacyCacheCatalog.Scan {
    let worker = Task.detached(priority: .userInitiated) { () throws -> LegacyCacheCatalog.Scan in
      guard url.isFileURL, url.startAccessingSecurityScopedResource() else {
        throw ServiceError("无法读取所选文件夹")
      }
      defer { url.stopAccessingSecurityScopedResource() }
      var error: NSError?
      var result: Result<LegacyCacheCatalog.Scan, Error>?
      NSFileCoordinator(filePresenter: nil).coordinate(
        readingItemAt: url, options: .withoutChanges, error: &error
      ) { inside in result = Result { try LegacyCacheCatalog.scan(inside) } }
      if let error { throw error }
      guard let result else { throw ServiceError("文件夹未响应") }
      return try result.get()
    }
    return try await withTaskCancellationHandler(
      operation: { try await worker.value }, onCancel: { worker.cancel() })
  }
  @MainActor private func restore(_ uid: String) async {
    guard !busy, uid == owner else { return }
    busy = true
    defer { busy = false }
    for item in list where checked.contains(item.id) {
      guard !Task.isCancelled, uid == owner else { return }
      var v = item.row(owner: uid)
      if !preserve {
        v.quality = nil
        v.audioQuality = nil
      }
      do {
        if let prior = Downloads.shared.existing(v, owner: uid), prior.phase != .failed {
          result[item.id] = "已在本机缓存列表"
          checked.remove(item.id)
          continue
        }
        if v.episode == nil {
          v.singleFile = try await BiliAPI.shared.offlineArchiveMenu(v.bvid, cid: v.cid, owner: uid)
            .singleFile
        }
        await Downloads.shared.start(v)
        guard !Task.isCancelled, uid == owner else { return }
        guard let row = Downloads.shared.existing(v, owner: uid), row.phase != .failed else {
          throw ServiceError(
            Downloads.shared.existing(v, owner: uid)?.error ?? Downloads.shared.issue ?? "无法恢复")
        }
        result[item.id] = "已加入缓存队列"
        checked.remove(item.id)
      } catch {
        if !Task.isCancelled && uid == owner { result[item.id] = error.localizedDescription }
      }
    }
  }
}
