import SwiftUI

struct DynamicEditPhotos: View {
  let source: DynamicRevision, scope: DynamicDraftScope
  @Binding var record: DynamicDraftFile
  @Binding var importing: Bool
  @Binding var issue: String?
  @EnvironmentObject private var accounts: AccountContext
  @State private var crop: Selection?
  @State private var liveConfirmation: Selection?
  struct Selection: Identifiable { let id: DynamicDraftFile.Asset }
  private var disk: DynamicDraftDisk { .app }
  var body: some View {
    let ordered = record.ordered
    ForEach(Array(ordered.enumerated()), id: \.element) { index, key in
      let live: Bool = {
        if case .original(let id) = key { return source.pictures.first { $0.id == id }?.live != nil }
        return false
      }()
      DraftImageTile(
        live: live,
        crop: {
          if live { liveConfirmation = .init(id: key) } else { crop = .init(id: key) }
        },
        remove: { remove(key) },
        moveLeft: index > 0 ? { move(index, to: index - 1) } : nil,
        moveRight: index + 1 < ordered.count ? { move(index, to: index + 1) } : nil
      ) {
        switch key {
        case .local(let id):
          LocalDraftThumbnail(url: disk.image(id, scope: scope), fill: true)
        case .original(let id):
          let p = source.pictures.first { $0.id == id }
          SiteThumbnail(url: p.flatMap { GalleryPicture.source($0.src) }) {
            $0.resizable().scaledToFill()
          } placeholder: {
            Color.secondary.opacity(0.1)
          }
        }
      }
    }
    DynamicPhotoDraft(
      scope: scope, images: $record.pictures, limit: 9 - (record.originals?.count ?? 0),
      importing: $importing, issue: $issue, showRows: false)
    Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
      .confirmationDialog(
        "裁剪后将使用静态图片",
        isPresented: Binding(
          get: { liveConfirmation != nil }, set: { if !$0 { liveConfirmation = nil } }),
        presenting: liveConfirmation
      ) { target in
        Button("继续裁剪") { crop = target }
        Button("取消", role: .cancel) {}
      }
      .piliSheet(item: $crop) { target in
        DynamicEditCropTarget(asset: target.id, source: source, scope: scope) { bytes in
          guard accounts.state.active == scope.owner,
            let at = record.ordered.firstIndex(of: target.id)
          else { throw ServiceError("草稿已变更") }
          let fresh = try disk.add(bytes, scope: scope)
          var order = record.ordered
          order[at] = .local(fresh)
          remove(target.id)
          record.pictures.append(fresh)
          record.order = order
        }
      }
  }
  private func move(_ from: Int, to: Int) {
    var all = record.ordered
    all.swapAt(from, to)
    record.order = all
  }
  private func remove(_ key: DynamicDraftFile.Asset) {
    switch key {
    case .local(let id): record.pictures.removeAll { $0 == id }
    case .original(let id): record.originals?.removeAll { $0 == id }
    }
    record.order?.removeAll { $0 == key }
  }
}
private struct DynamicEditCropTarget: View {
  let asset: DynamicDraftFile.Asset, source: DynamicRevision, scope: DynamicDraftScope,
    save: (Data) throws -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var local: URL?
  @State private var assets = GalleryAssets()
  @State private var issue: String?
  var body: some View {
    Group {
      if let local {
        DynamicCrop(url: local, save: save)
      } else if let issue {
        VStack {
          Text(issue)
          Button("关闭") { dismiss() }
        }
      } else {
        ProgressView("正在读取图片")
      }
    }.task {
      do {
        switch asset {
        case .local(let id): local = DynamicDraftDisk.app.image(id, scope: scope)
        case .original(let id):
          guard let raw = source.pictures.first(where: { $0.id == id })?.src,
            let url = GalleryPicture.source(raw)
          else { throw ServiceError("原图地址无效") }
          let file = try await assets.local(url)
          try Task.checkCancellation()
          local = file
        }
      } catch { if !Task.isCancelled { self.issue = error.localizedDescription } }
    }
  }
}
