import ImageIO
import PhotosUI
import SwiftUI

extension BiliAPI {
  func folderCover(_ jpeg: Data, uid: String) async throws -> String {
    guard !jpeg.isEmpty, jpeg.count <= 8 * 1024 * 1024,
      let owner = try await AccountJar.shared.current(),
      owner.id == uid, let csrf = owner.csrf
    else { throw ServiceError("无法上传收藏夹封面") }
    let boundary = "Pili-" + UUID().uuidString
    var data = Data()
    func append(_ s: String) { data.append(contentsOf: s.utf8) }
    for (name, value) in [("bucket", "medialist"), ("dir", "cover"), ("csrf", csrf)] {
      append(
        "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }
    append(
      "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"cover.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n"
    )
    data.append(jpeg)
    append("\r\n--\(boundary)--\r\n")
    var req = URLRequest(
      url: URL(string: "https://api.bilibili.com/x/upload/web/image")!, timeoutInterval: 30)
    req.httpMethod = "POST"
    req.httpBody = data
    req.httpShouldHandleCookies = false
    req.setValue(owner.header, forHTTPHeaderField: "Cookie")
    req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    req.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
    struct Result: Decodable {
      struct Image: Decodable { let location: String? }
      let code: Int, message: String?, data: Image?
    }
    let (bytes, raw) = try await webResponse(req, identity: owner)
    guard (raw as? HTTPURLResponse)?.statusCode == 200 else { throw ServiceError("封面上传失败") }
    let reply = try JSONDecoder().decode(Result.self, from: bytes)
    guard reply.code == 0, let source = reply.data?.location,
      let url = GalleryPicture.source(source)
    else {
      throw ServiceError(reply.message ?? "未收到封面地址")
    }
    return url.absoluteString
  }
}
struct FolderCoverPicker: View {
  @Binding var cover: String
  @Binding var draft: Data?
  @Binding var editing: Bool
  @State private var photo: UIImage?
  @State private var item: PhotosPickerItem?
  @State private var error: String?
  @State private var scale = 1.0
  @State private var x = 0.5
  @State private var y = 0.5
  @State private var aspect = 0
  private func rect(_ image: UIImage, size: CGSize) -> CGRect {
    let factor = max(size.width / image.size.width, size.height / image.size.height) * scale
    let w = image.size.width * factor
    let h = image.size.height * factor
    return .init(x: (size.width - w) * x, y: (size.height - h) * y, width: w, height: h)
  }
  private func ratio(_ image: UIImage) -> CGFloat {
    aspect == 0 ? image.size.width / image.size.height : aspect == 1 ? 16.0 / 9 : 1
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let photo {
        Picker("裁剪比例", selection: $aspect) {
          Text("原比例").tag(0)
          Text("16:9").tag(1)
          Text("方形").tag(2)
        }.pickerStyle(.segmented)
        let h = min(180, 240 / ratio(photo))
        let w = h * ratio(photo)
        let f = rect(photo, size: .init(width: w, height: h))
        ZStack(alignment: .topLeading) {
          Color.white
          Image(uiImage: photo).resizable().frame(width: f.width, height: f.height).offset(
            x: f.minX, y: f.minY)
        }.frame(width: w, height: h).clipped().accessibilityLabel("封面裁剪预览")
        LabeledContent("缩放") { Slider(value: $scale, in: 1...4) }
        if f.width > w + 0.5 { LabeledContent("左右") { Slider(value: $x, in: 0...1) } }
        if f.height > h + 0.5 { LabeledContent("上下") { Slider(value: $y, in: 0...1) } }
        Button("使用此裁剪") {
          let r = ratio(photo)
          let width = min(1280, 1280 * r)
          let size = CGSize(width: max(1, width.rounded()), height: max(1, (width / r).rounded()))
          let format = UIGraphicsImageRendererFormat()
          format.opaque = true
          format.scale = 1
          draft = UIGraphicsImageRenderer(size: size, format: format).jpegData(
            withCompressionQuality: 0.91
          ) { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            photo.draw(in: rect(photo, size: size))
          }
          self.photo = nil
          item = nil
          editing = false
        }
        Button("取消裁剪") {
          self.photo = nil
          item = nil
          editing = false
        }
      } else if let draft {
        FolderCoverPreview(data: draft)
      } else if let url = GalleryPicture.source(cover) {
        SiteThumbnail(url: url) {
          $0.resizable().scaledToFit()
        } placeholder: {
          Color.clear
        }.frame(maxHeight: 130)
      }
      PhotosPicker(selection: $item, matching: .images) {
        Label(cover.isEmpty && draft == nil ? "选取封面" : "替换封面", systemImage: "photo")
      }
      if !cover.isEmpty || draft != nil || photo != nil {
        Button("移除封面", role: .destructive) {
          cover = ""
          draft = nil
          photo = nil
          item = nil
          editing = false
        }
      }
      if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
    }.task(id: item) {
      guard let item else { return }
      editing = true
      do {
        guard let data = try await item.loadTransferable(type: Data.self),
          data.count <= 32 * 1024 * 1024
        else { throw ServiceError("无法读取这张图片") }
        let decoding = Task.detached(priority: .userInitiated) {
          try Task.checkCancellation()
          guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: 2048,
              kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
          else { throw ServiceError("无法读取这张图片") }
          return thumb
        }
        let thumb = try await withTaskCancellationHandler {
          try await decoding.value
        } onCancel: { decoding.cancel() }
        try Task.checkCancellation()
        photo = UIImage(cgImage: thumb)
        scale = 1
        x = 0.5
        y = 0.5
        aspect = 0
        error = nil
      } catch {
        if !Task.isCancelled {
          self.error = error.localizedDescription
          editing = photo != nil
        }
      }
    }
  }
}

private struct FolderCoverPreview: View {
  let data: Data
  @State private var image: UIImage?
  var body: some View {
    Group {
      if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 130) }
    }.task(id: data) {
      let bytes = data
      let decoding = Task.detached(priority: .utility) {
        try Task.checkCancellation()
        return try DynamicPhotoImage.thumb(bytes, limit: 1280)
      }
      do {
        let cg = try await withTaskCancellationHandler {
          try await decoding.value
        } onCancel: { decoding.cancel() }
        try Task.checkCancellation()
        image = UIImage(cgImage: cg)
      } catch { if !Task.isCancelled { image = nil } }
    }
  }
}
