import ImageIO
import PhotosUI
import SwiftUI

enum DynamicPhotoImage {
  static func thumb(_ bytes: Data, limit: Int) throws -> CGImage {
    guard bytes.count <= 40 * 1024 * 1024,
      let source = CGImageSourceCreateWithData(bytes as CFData, nil),
      let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int,
      w > 0, h > 0, w <= 80000, h <= 80000, Int64(w) * Int64(h) <= 200_000_000,
      let cg = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: limit,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    else { throw ServiceError("无法读取图片") }
    return cg
  }
  static func jpeg(_ data: Data) throws -> Data {
    let cg = try thumb(data, limit: 6144)
    var q = 0.94
    while q >= 0.54 {
      if let bytes = UIImage(cgImage: cg).jpegData(compressionQuality: q),
        bytes.count <= 16 * 1024 * 1024
      {
        return bytes
      }
      q -= 0.12
    }
    throw ServiceError("图片过大")
  }
}
struct DynamicPhotoDraft: View {
  let scope: DynamicDraftScope
  @Binding var images: [UUID]
  let limit: Int
  @Binding var importing: Bool
  @Binding var issue: String?
  var showRows = true
  @EnvironmentObject private var accounts: AccountContext
  @State private var picked = [PhotosPickerItem]()
  @State private var cropping: Photo?
  struct Photo: Identifiable { let id: UUID }
  private let disk = DynamicDraftDisk.app
  /// Laid out as tiles of a horizontal strip; the caller supplies the HStack/ScrollView.
  var body: some View {
    if showRows {
      ForEach(Array(images.enumerated()), id: \.element) { index, id in
        DraftImageTile(
          crop: { cropping = .init(id: id) },
          remove: { images.removeAll { $0 == id } },
          moveLeft: index > 0 ? { images.swapAt(index, index - 1) } : nil,
          moveRight: index + 1 < images.count ? { images.swapAt(index, index + 1) } : nil
        ) {
          LocalDraftThumbnail(url: disk.image(id, scope: scope), fill: true)
        }
      }
    }
    if images.count < limit {
      PhotosPicker(
        selection: $picked, maxSelectionCount: limit - images.count, selectionBehavior: .ordered,
        matching: .images
      ) {
        ComposerAddPhotoLabel(busy: importing)
      }.buttonStyle(.plain).disabled(importing).onChange(of: picked) { _, items in
        guard !items.isEmpty, !importing, accounts.state.active == scope.owner else { return }
        importing = true
        picked = []
        Task {
          defer { importing = false }
          do {
            for item in items.prefix(max(0, limit - images.count)) {
              guard accounts.state.active == scope.owner,
                let raw = try await item.loadTransferable(type: Data.self)
              else { throw ServiceError("未能读取图片") }
              let bytes = try await Task.detached(priority: .utility) {
                try DynamicPhotoImage.jpeg(raw)
              }.value
              guard accounts.state.active == scope.owner else { throw ServiceError("账号已切换") }
              images.append(try disk.add(bytes, scope: scope))
            }
          } catch { issue = error.localizedDescription }
        }
      }
    }
    Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
      .piliSheet(item: $cropping) { selection in
        DynamicCrop(url: disk.image(selection.id, scope: scope)) { bytes in
          guard accounts.state.active == scope.owner, let i = images.firstIndex(of: selection.id)
          else { throw ServiceError("草稿已变更") }
          images[i] = try disk.add(bytes, scope: scope)
        }
      }
  }
}
struct LocalDraftThumbnail: View {
  let url: URL
  var fill = false
  @State private var image: UIImage?
  var body: some View {
    Group {
      if let image {
        if fill {
          Color.clear.overlay { Image(uiImage: image).resizable().scaledToFill() }
        } else {
          Image(uiImage: image).resizable().scaledToFit()
        }
      } else {
        Color.secondary.opacity(0.1)
      }
    }
    .task(id: url) {
      image = nil
      let cg = await Task.detached(priority: .utility) {
        try? DynamicPhotoImage.thumb(Data(contentsOf: url, options: .mappedIfSafe), limit: 200)
      }.value
      if let cg, !Task.isCancelled { image = UIImage(cgImage: cg) }
    }
  }
}
struct DynamicCrop: View {
  let url: URL, save: (Data) throws -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var image: UIImage?
  @State private var lo = CGPoint(x: 0, y: 0)
  @State private var hi = CGPoint(x: 1, y: 1)
  @State private var error: String?
  var body: some View {
    PiliNavigationStack {
      VStack {
        if let img = image {
          GeometryReader { g in
            let scale = min(g.size.width / img.size.width, g.size.height / img.size.height)
            let size = CGSize(
              width: max(1, img.size.width * scale), height: max(1, img.size.height * scale))
            ZStack(alignment: .topLeading) {
              Image(uiImage: img).resizable().frame(width: size.width, height: size.height)
              Rectangle().strokeBorder(.white, lineWidth: 2)
                .frame(width: (hi.x - lo.x) * size.width, height: (hi.y - lo.y) * size.height)
                .offset(x: lo.x * size.width, y: lo.y * size.height)
              grip(start: true, size: size)
              grip(start: false, size: size)
            }.coordinateSpace(name: "dynamic.crop").frame(width: size.width, height: size.height)
              .position(x: g.size.width / 2, y: g.size.height / 2)
          }.padding(18)
          Button("还原范围") {
            lo = .zero
            hi = .init(x: 1, y: 1)
          }
        } else if error == nil {
          ProgressView()
        }
        if let error { Text(error).foregroundStyle(.secondary) }
      }.navigationTitle("裁剪图片").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") {
            guard let source = image?.cgImage else { return }
            let rect = CGRect(
              x: lo.x * CGFloat(source.width), y: lo.y * CGFloat(source.height),
              width: (hi.x - lo.x) * CGFloat(source.width),
              height: (hi.y - lo.y) * CGFloat(source.height))
            guard let cropped = source.cropping(to: rect.integral),
              let bytes = UIImage(cgImage: cropped).jpegData(compressionQuality: 0.93)
            else {
              error = "未能裁剪图片"
              return
            }
            do {
              try save(bytes)
              dismiss()
            } catch { self.error = error.localizedDescription }
          }.disabled(image == nil)
        }
      }.task {
        do {
          let cg = try await Task.detached {
            try DynamicPhotoImage.thumb(Data(contentsOf: url, options: .mappedIfSafe), limit: 6144)
          }.value
          try Task.checkCancellation()
          image = UIImage(cgImage: cg)
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
      }
    }
  }
  private func grip(start: Bool, size: CGSize) -> some View {
    let pos = start ? lo : hi
    return Circle().fill(.blue).frame(width: 19, height: 19).frame(width: 44, height: 44)
      .contentShape(Rectangle())
      .position(x: pos.x * size.width, y: pos.y * size.height)
      .gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .named("dynamic.crop")).onChanged { p in
          let x = p.location.x / size.width
          let y = p.location.y / size.height
          if start {
            lo = CGPoint(x: min(hi.x - 0.04, max(0, x)), y: min(hi.y - 0.04, max(0, y)))
          } else {
            hi = CGPoint(x: max(lo.x + 0.04, min(1, x)), y: max(lo.y + 0.04, min(1, y)))
          }
        }
      ).accessibilityLabel(start ? "左上角" : "右下角")
  }
}
