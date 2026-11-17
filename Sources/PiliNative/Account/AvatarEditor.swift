import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct AvatarEditor: View {
  let uid: String, changed: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var picker: PhotosPickerItem?
  @State private var photo: UIImage?
  @State private var gif: Data?
  @State private var keepAnimation = true
  @State private var scale = 1.0
  @State private var horizontal = 0.5
  @State private var vertical = 0.5
  @State private var busy = false
  @State private var issue: String?
  private let side: CGFloat = 224
  private func rect(_ image: UIImage, side: CGFloat) -> CGRect {
    let factor = max(side / image.size.width, side / image.size.height) * CGFloat(scale)
    let w = image.size.width * factor
    let h = image.size.height * factor
    return CGRect(x: (side - w) * horizontal, y: (side - h) * vertical, width: w, height: h)
  }
  var body: some View {
    Form {
      PhotosPicker(selection: $picker, matching: .images) {
        Label(photo == nil ? "选择照片" : "重新选择", systemImage: "photo")
      }
      if let photo {
        if gif != nil { Toggle("保留动图", isOn: $keepAnimation) }
        if gif != nil && keepAnimation {
          Image(uiImage: photo).resizable().scaledToFit().frame(maxHeight: side)
        } else {
          let frame = rect(photo, side: side)
          HStack {
            Spacer()
            ZStack(alignment: .topLeading) {
              Color.white
              Image(uiImage: photo).resizable().frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
            }.frame(width: side, height: side).clipped().accessibilityLabel("头像预览")
            Spacer()
          }
          LabeledContent("缩放") { Slider(value: $scale, in: 1...4) }
          if frame.width > side + 0.5 {
            LabeledContent("水平位置") { Slider(value: $horizontal, in: 0...1) }
          }
          if frame.height > side + 0.5 {
            LabeledContent("垂直位置") { Slider(value: $vertical, in: 0...1) }
          }
        }
        Button("保存头像") { Task { await save(photo) } }.disabled(busy)
      }
      if busy { ProgressView() }
      if let issue { Text(issue).foregroundStyle(.secondary) }
    }.navigationTitle("修改头像").disabled(busy)
      .task(id: picker) {
        guard let picker else { return }
        photo = nil
        gif = nil
        issue = nil
        do {
          guard let d = try await picker.loadTransferable(type: Data.self),
            d.count <= 32 * 1024 * 1024,
            let source = CGImageSourceCreateWithData(d as CFData, nil)
          else { throw ServiceError("照片无法读取或过大") }
          let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1800,
          ]
          guard let img = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
          else { throw ServiceError("不是可用的图片") }
          try Task.checkCancellation()
          photo = UIImage(cgImage: img)
          if CGImageSourceGetType(source) as String? == UTType.gif.identifier
            && CGImageSourceGetCount(source) > 1 && d.count <= 5 * 1024 * 1024
          {
            gif = d
          }
          scale = 1
          horizontal = 0.5
          vertical = 0.5
          keepAnimation = true
        } catch { if !Task.isCancelled { issue = error.localizedDescription } }
      }
  }
  @MainActor private func save(_ image: UIImage) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      let bytes: Data
      let animated = keepAnimation && gif != nil
      if animated, let gif {
        bytes = gif
      } else {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: .init(width: 768, height: 768), format: format)
        bytes = renderer.jpegData(withCompressionQuality: 0.9) { ctx in
          UIColor.white.setFill()
          ctx.fill(.init(x: 0, y: 0, width: 768, height: 768))
          image.draw(in: rect(image, side: 768))
        }
      }
      try await BiliAPI.shared.uploadAvatar(bytes, uid: uid, animated: animated)
      changed()
      dismiss()
    } catch { issue = error.localizedDescription }
  }
}
