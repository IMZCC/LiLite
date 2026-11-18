import CoreImage.CIFilterBuiltins
import ImageIO
import Photos
import SwiftUI

struct PosterContent {
  let title: String, body: String, author: String, date: String, kind: String, link: URL,
    cover: URL?
  var gallery: [URL] = []
  static func moment(_ e: DynamicEntry, link: URL) -> Self {
    var text = [String]()
    var media = [URL]()
    func add(_ v: String?) { if let v, !v.isEmpty, text.last != v { text.append(v) } }
    func append(_ v: MomentResources) {
      for c in v.cards {
        add(c.title)
        add(c.sub)
        if let u = c.cover { media.append(u) }
      }
      if let r = v.reserve {
        add(r.title)
        add([r.sub1, r.sub2].filter { !$0.isEmpty }.joined(separator: " · "))
      }
      media += v.pictures.map(\.url)
    }
    if let t = e.topic { add("#" + t.name) }
    add(e.body)
    if !e.blockedAttachment {
      media += e.pictures
      if let a = e.presentation.attachment {
        add(a.title)
        if let u = a.cover { media.append(u) }
      }
      if let video = e.video {
        add(video.title)
        if let u = video.cover { media.append(u) }
      }
    }
    append(e.resources)
    if let a = e.originalAuthor { add("转发自 @" + (a.uname ?? "")) }
    if !e.originalNodes.isEmpty {
      add(e.originalNodes.map(\.text).joined())
    } else {
      add(e.summary)
    }
    if let original = e.originalResources { append(original) }
    var unique = Set<URL>()
    media = media.filter { unique.insert($0).inserted }
    var post = Self(
      title: e.video?.title ?? "动态", body: text.joined(separator: "\n"), author: e.author,
      date: e.date, kind: "动态", link: link, cover: media.first)
    post.gallery = Array(media.dropFirst())
    return post
  }
  static func comment(oid: Int64, type: Int, root: Int64?, reply: Reply) -> Self {
    let key=reply.threadRoot != reply.rpid ? reply.threadRoot:(root ?? reply.rpid)
    let nested=key != reply.rpid
    var c = URLComponents()
    if type == 1 {
      c.scheme = "https"
      c.host = "www.bilibili.com"
      c.path = "/video/av\(oid)"
      c.queryItems = [
        .init(name: "comment_on", value: "1"), .init(name: "comment_root_id", value: String(key)),
      ]
      if nested {
        c.queryItems?.append(.init(name: "comment_secondary_id", value: String(reply.rpid)))
      }
    } else {
      c.scheme = "bilibili"
      c.host = "comment"
      c.path = "/detail/\(type)/\(oid)/\(key)/"
      if nested { c.queryItems = [.init(name: "anchor", value: String(reply.rpid))] }
    }
    let images=(reply.content.pictures ?? []).compactMap{$0.img_src.flatMap(GalleryPicture.source)}
    var poster=Self(
      title: "评论", body: reply.content.message, author: reply.member?.uname ?? "",
      date: reply.ctime.map {
        Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened)
      } ?? "", kind: "评论", link: c.url!,
      cover: images.first)
    var seen=Set(images.prefix(1));poster.gallery=images.dropFirst().filter{seen.insert($0).inserted};return poster
  }
}
struct SharePoster: View {
  let content: PosterContent
  @State private var cover: UIImage?
  @State private var qr: UIImage?
  @State private var pictures = [URL: UIImage]()
  @State private var showBottom = true
  @State private var pictureFolder: LocalFolderChoice?
  @State private var load = false
  @State private var showCover = true
  @State private var dark = false
  @State private var busy = false
  @State private var result: String?
  @State private var share: Artifact?
  struct Artifact: Identifiable {
    let id = UUID()
    let image: UIImage
    init(image: UIImage) { self.image = image }
  }
  var body: some View {
    // The original's poster: the card alone in the middle, a row of round actions under it.
    // Card options move to the toolbar menu.
    ScrollView {
      VStack(spacing: 22) {
        card.frame(maxWidth: .infinity).shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        HStack(spacing: 0) {
          action(pictureFolder == nil ? "保存图片" : "保存", "arrow.down.to.line") { Task { await save() } }
            .disabled((showBottom && qr == nil) || busy || load)
          action("分享", "square.and.arrow.up") { if let img = render() { share = Artifact(image: img) } }
            .disabled((showBottom && qr == nil) || busy || load)
          action("复制链接", "link") {
            UIPasteboard.general.url = content.link
            result = "链接已复制"
          }
        }
        if let result { Text(result).font(.footnote).foregroundStyle(.secondary) }
      }.padding()
    }
    .background(Color(uiColor: .secondarySystemBackground))
    .navigationTitle("分享卡片").navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          if cover != nil { Toggle("显示封面", isOn: $showCover) }
          Toggle("显示二维码和页脚", isOn: $showBottom)
          Toggle("深色卡片", isOn: $dark)
        } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("卡片选项")
      }
    }
    .task(id: content.link) {
      qr = nil
      cover = nil
      load = true
      defer { load = false }
      let filter = CIFilter.qrCodeGenerator()
      filter.message = Data(content.link.absoluteString.utf8)
      filter.correctionLevel = "M"
      if let output = filter.outputImage?.transformed(by: .init(scaleX: 7, y: 7)),
        let cg = CIContext().createCGImage(output, from: output.extent)
      {
        qr = UIImage(cgImage: cg)
      }
      pictures = [:]
      pictureFolder = try? await FolderGrants.shared.current(.pictures)
      if let u = content.cover { cover = await picture(u, pixels: 960) }
      for u in content.gallery {
        if Task.isCancelled { return }
        if let image = await picture(u, pixels: 400) { pictures[u] = image }
      }
    }.sheet(item: $share) { v in PosterActivity(image: v.image) }
  }
  private func picture(_ url: URL, pixels: Int) async -> UIImage? {
    guard url.scheme == "https", url.user == nil, url.password == nil,
      let h = url.host?.lowercased(),
      ["hdslb.com", "biliimg.com", "bilibili.com"].contains(where: {
        h == $0 || h.hasSuffix("." + $0)
      })
    else { return nil }
    return try? await ArtworkStore.shared.image(url, pixels: pixels, maximum: 15 * ArtworkStore.mib)
  }
  private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
    Button(action: run) {
      VStack(spacing: 6) {
        Image(systemName: symbol).font(.system(size: 18, weight: .medium))
          .frame(width: 48, height: 48).background(Color(uiColor: .systemBackground), in: Circle())
        Text(title).font(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity)
    }.buttonStyle(.plain)
  }
  private var card: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let cover, showCover {
        Image(uiImage: cover).resizable().scaledToFit().frame(maxHeight: 270).frame(
          maxWidth: .infinity)
      }
      Text(content.title).font(.title3.bold())
      if !content.body.isEmpty {
        Text(content.body).font(.body).fixedSize(horizontal: false, vertical: true)
      }
      if showCover && !pictures.isEmpty {
        let columns = min(3, max(1, pictures.count))
        let side = (260.0 - CGFloat(columns - 1) * 4) / CGFloat(columns)
        VStack(alignment: .leading, spacing: 4) {
          ForEach(Array(stride(from: 0, to: content.gallery.count, by: columns)), id: \.self) {
            start in
            HStack(spacing: 4) {
              ForEach(start..<min(start + columns, content.gallery.count), id: \.self) { i in
                if let image = pictures[content.gallery[i]] {
                  Image(uiImage: image).resizable().scaledToFill().frame(width: side, height: side)
                    .clipped()
                }
              }
            }
          }
        }
      }
      if !content.author.isEmpty { Text("@" + content.author).font(.subheadline) }
      if showBottom {
        Divider()
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("轻哩").font(.headline)
            Text("扫码查看\(content.kind)").font(.caption)
            if !content.date.isEmpty { Text(content.date).font(.caption2) }
          }
          Spacer()
          if let qr {
            Image(uiImage: qr).interpolation(.none).resizable().frame(width: 76, height: 76)
              .padding(
                8
              ).background(.white)
          }
        }
      }
    }.padding(16).frame(width: 292, alignment: .leading).foregroundStyle(
      dark ? Color.white : Color.black
    ).background(dark ? Color(white: 0.12) : Color.white).environment(
      \.colorScheme, dark ? .dark : .light)
  }
  @MainActor private func render() -> UIImage? {
    let renderer = ImageRenderer(content: card)
    renderer.scale = 3
    guard let image = renderer.uiImage else {
      result = "生成图片失败"
      return nil
    }
    return image
  }
  @MainActor private func save() async {
    guard !busy, let image = render() else { return }
    busy = true
    defer { busy = false }
    do {
      if let selected = try await FolderGrants.shared.current(.pictures) {
        guard let data = image.pngData() else { throw ServiceError("无法生成图片") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
          UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try data.write(to: tmp, options: .atomic)
        let stem = content.kind + "-" + content.link.lastPathComponent
        try await FolderGrants.shared.withFolder(selected.id, writing: true) { folder in
          try FolderExport.write(
            [.init(source: tmp, stem: stem, ext: "png")], into: folder, group: nil)
        }
        result = "已保存到 " + selected.name
        return
      }
    } catch {
      result = error.localizedDescription
      return
    }
    let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard auth == .authorized || auth == .limited else {
      result = "请在系统设置中允许添加照片"
      return
    }
    do {
      try await PHPhotoLibrary.shared().performChanges {
        PHAssetChangeRequest.creationRequestForAsset(from: image)
      }
      result = "已存到照片"
    } catch { result = error.localizedDescription }
  }
}
private struct PosterActivity: UIViewControllerRepresentable {
  let image: UIImage
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: [image], applicationActivities: nil)
  }
  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
