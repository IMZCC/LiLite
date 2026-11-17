import PhotosUI
import SwiftUI

struct ReplyComposePhoto: Identifiable, Equatable {
  var id: UUID = UUID()
  let file: URL
}
@MainActor final class ReplyComposeSession: ObservableObject {
  struct Slot {
    var text = ReplyDraft(), cursor: NSRange?, photos = [ReplyComposePhoto](), share = false
  }
  private let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
    "pili-comment-" + UUID().uuidString, isDirectory: true)
  var slots = [ReplyComposeAddress: Slot]()
  deinit { try? FileManager.default.removeItem(at: dir) }
  func stage(_ bytes: Data) throws -> ReplyComposePhoto {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let u = dir.appendingPathComponent(UUID().uuidString + ".jpg")
    try bytes.write(to: u, options: .atomic)
    return .init(file: u)
  }
}
/// The composer's picture strip, as in the original: 75pt thumbnails in a row under the text,
/// each with a remove button; tap to crop, long-press to reorder. The photo picker and the video
/// frame capture are opened from the composer's toolbar through `picking` and `shot`.
struct ReplyComposePhotos: View {
  @Binding var pictures: [ReplyComposePhoto]
  let session: ReplyComposeSession, owner: String, player: PlayerModel?, current: () -> Bool
  @Binding var importing: Bool
  @Binding var picking: Bool
  @Binding var shot: Bool
  let error: (String) -> Void
  @EnvironmentObject private var accounts: AccountContext
  @State private var picks = [PhotosPickerItem]()
  @State private var crop: ReplyComposePhoto?
  @State private var shotSource: TimelineSource?
  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 10) {
        ForEach(Array(pictures.enumerated()), id: \.element.id) { i, p in
          thumb(p, at: i)
        }
        if importing {
          ProgressView().frame(width: 75, height: 75)
            .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
        }
      }.padding(.horizontal, 15).padding(.top, 6)
    }
    .frame(height: pictures.isEmpty && !importing ? 0 : 91)
    .clipped()
    .photosPicker(
      isPresented: $picking, selection: $picks, maxSelectionCount: max(1, 9 - pictures.count),
      selectionBehavior: .ordered, matching: .images
    )
    .onChange(of: shot) { _, open in
      guard open else { return }
      shotSource = player?.timeline.source
      if shotSource == nil || pictures.count >= 9 { shot = false }
    }
    .onChange(of: picks) { _, items in
      guard !items.isEmpty else { return }
      picks = []
      importing = true
      Task {
        defer { importing = false }
        do {
          for item in items.prefix(max(0, 9 - pictures.count)) {
            guard let data = try await item.loadTransferable(type: Data.self) else {
              throw ServiceError("无法读取图片")
            }
            let bytes = try await Task.detached(priority: .utility) {
              try DynamicPhotoImage.jpeg(data)
            }.value
            guard owner == accounts.state.active, current() else { return }
            pictures.append(try session.stage(bytes))
          }
        } catch { self.error(error.localizedDescription) }
      }
    }
    .piliSheet(item: $crop) { pic in
      DynamicCrop(url: pic.file) { data in
        guard owner == accounts.state.active, current(),
          let i = pictures.firstIndex(where: { $0.id == pic.id })
        else { return }
        pictures[i] = try session.stage(data)
      }
    }
    .piliSheet(isPresented: $shot) {
      if let model = player {
        ReplyFrameSelection(
          model: model,
          allowed: {
            current() && model.timeline.source == shotSource && shotSource != nil
              && model.isPreview != true && owner == accounts.state.active
          }
        ) { data in
          guard current(), model.timeline.source == shotSource, shotSource != nil, !model.isPreview,
            owner == accounts.state.active, pictures.count < 9
          else { return }
          do {
            pictures.append(try session.stage(data))
            shot = false
          } catch { self.error(error.localizedDescription) }
        }
      }
    }
  }
  private func thumb(_ p: ReplyComposePhoto, at i: Int) -> some View {
    Button { crop = p } label: {
      ReplyComposeThumbnail(url: p.file)
      .frame(width: 75, height: 75)
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .overlay(alignment: .topTrailing) {
      Button {
        withAnimation(.snappy) { pictures.removeAll { $0.id == p.id } }
      } label: {
        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
          .frame(width: 20, height: 20).background(.black.opacity(0.55), in: Circle())
      }
      .buttonStyle(.plain).padding(3).accessibilityLabel("移除图片")
    }
    .contextMenu {
      Button("裁剪", systemImage: "crop") { crop = p }
      if i > 0 { Button("前移", systemImage: "arrow.left") { pictures.swapAt(i, i - 1) } }
      if i + 1 < pictures.count {
        Button("后移", systemImage: "arrow.right") { pictures.swapAt(i, i + 1) }
      }
      Button("移除", systemImage: "trash", role: .destructive) { pictures.removeAll { $0.id == p.id } }
    }
  }
}
private struct ReplyComposeThumbnail: View {
  let url: URL
  @Environment(\.displayScale) private var scale
  @State private var image: UIImage?
  @State private var loaded: Request?
  private struct Request: Equatable {
    let url: URL
    let pixels: Int
  }
  var body: some View {
    let request = Request(url: url, pixels: Int(ceil(75 * max(1, scale))))
    Group {
      if loaded?.url == url, let image {
        Image(uiImage: image).resizable().scaledToFill()
      } else {
        Color(uiColor: .secondarySystemFill)
      }
    }.task(id: request) {
      if loaded == request, image != nil { return }
      let work = Task.detached(priority: .utility) {
        try Task.checkCancellation()
        let bytes = try Data(contentsOf: request.url, options: .mappedIfSafe)
        let cg = try DynamicPhotoImage.thumb(bytes, limit: request.pixels)
        try Task.checkCancellation()
        return cg
      }
      do {
        let cg = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        image = UIImage(cgImage: cg)
        loaded = request
      } catch { /* Keep the existing placeholder when a staged file is unavailable. */ }
    }
  }
}
private struct ReplyFrameSelection: View {
  let model: PlayerModel, allowed: () -> Bool, select: (Data) -> Void
  @Environment(\.dismiss) private var dismiss
  @StateObject private var frame: FrameCapture
  init(model: PlayerModel, allowed: @escaping () -> Bool, select: @escaping (Data) -> Void) {
    self.model = model
    self.allowed = allowed
    self.select = select
    _frame = StateObject(wrappedValue: FrameCapture(model.engine))
  }
  var body: some View {
    PiliNavigationStack {
      Form {
        if frame.busy { ProgressView() }
        if let img = frame.thumbnail {
          Image(uiImage: img).resizable().scaledToFit()
          Button("加入评论") {
            if allowed(), let bytes = img.jpegData(compressionQuality: 0.85) { select(bytes) }
          }
        }
        if let message = frame.note { Text(message) }
        Button("重新截取") { if allowed() { frame.capture(gif: false, length: 1, fps: 1) } }.disabled(
          frame.busy)
      }.navigationTitle("视频截图").toolbar { Button("取消") { dismiss() } }
    }.onAppear { if allowed() { frame.capture(gif: false, length: 1, fps: 1) } }.onDisappear {
      frame.close()
    }
  }
}
