import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

enum GalleryPhotoPermission: LocalizedError {
  case denied
  var errorDescription: String? { "请在系统设置中允许保存到照片" }
  static func request() async throws {
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard status == .authorized || status == .limited else { throw Self.denied }
  }
}

actor GalleryAssets {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
    "pili-gallery-" + UUID().uuidString, isDirectory: true)
  private var entries: [URL: URL] = [:], jobs: [URL: Task<URL, Error>] = [:]
  private var proxy: APIProxy
  private var session: URLSession
  private static func makeSession(_ proxy: APIProxy) -> URLSession {
    let c = URLSessionConfiguration.ephemeral
    c.httpCookieStorage = nil
    c.urlCredentialStorage = nil
    c.httpShouldSetCookies = false
    proxy.apply(to: c)
    return URLSession(configuration: c, delegate: APIRedirectPolicy(), delegateQueue: nil)
  }
  init() {
    let value = APIProxy.current()
    proxy = value
    session = Self.makeSession(value)
  }
  deinit {
    session.invalidateAndCancel()
    try? FileManager.default.removeItem(at: folder)
  }
  func local(_ url: URL, movie: Bool = false) async throws -> URL {
    let current = APIProxy.current()
    if current != proxy {
      session.finishTasksAndInvalidate()
      session = Self.makeSession(current)
      proxy = current
    }
    if let hit = entries[url] { return hit }
    if let job = jobs[url] { return try await job.value }
    guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
      throw ServiceError("媒体地址无效")
    }
    let session = self.session
    let folder = self.folder
    let job = Task<URL, Error> {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      var r = URLRequest(url: url, timeoutInterval: 35)
      r.httpShouldHandleCookies = false
      r.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
      let (tmp, resp) = try await session.download(for: r)
      guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
        let size = try tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0,
        size <= (movie ? 256 : 64) * 1024 * 1024
      else { throw ServiceError(movie ? "实况视频未能下载" : "图片未能下载") }
      let ext: String
      if movie {
        ext = resp.mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? "mp4"
      } else {
        guard let source = CGImageSourceCreateWithURL(tmp as CFURL, nil),
          CGImageSourceGetCount(source) > 0, let type = CGImageSourceGetType(source)
        else { throw ServiceError("无法识别图片") }
        ext = UTType(type as String)?.preferredFilenameExtension ?? "img"
      }
      let dest = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
      try FileManager.default.moveItem(at: tmp, to: dest)
      return dest
    }
    jobs[url] = job
    defer { jobs[url] = nil }
    let result = try await job.value
    entries[url] = result
    return result
  }
  func savePictures(_ images: [GalleryPicture]) async throws -> Int {
    if let choice = try await FolderGrants.shared.current(.pictures) {
      var seen = Set<URL>()
      var exports: [FolderExport.File] = []
      for photo in images where seen.insert(photo.url).inserted {
        let source = try await local(photo.url)
        try Task.checkCancellation()
        exports.append(
          .init(
            source: source, stem: photo.url.deletingPathExtension().lastPathComponent,
            ext: source.pathExtension))
      }
      let files = exports
      try await FolderGrants.shared.withFolder(choice.id, writing: true) {
        try FolderExport.write(files, into: $0, group: files.count > 1 ? "轻哩 原图" : nil)
      }
      return files.count
    }
    try await GalleryPhotoPermission.request()
    var files = [URL]()
    var seen = Set<URL>()
    for p in images where seen.insert(p.url).inserted {
      files.append(try await local(p.url))
      try Task.checkCancellation()
    }
    guard !files.isEmpty else { throw ServiceError("没有可保存的图片") }
    let resources = files
    try await PHPhotoLibrary.shared().performChanges {
      for u in resources {
        PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: u, options: nil)
      }
    }
    return resources.count
  }
  func saveLive(_ photo: GalleryPicture) async throws {
    guard let video = photo.motion else { throw ServiceError("没有实况视频") }
    let selected = try await FolderGrants.shared.current(.pictures)
    if selected == nil { try await GalleryPhotoPermission.request() }
    async let image = local(photo.url)
    async let movie = local(video, movie: true)
    if let choice = selected {
      let folder = try LivePhotoPair.temporaryFolder()
      defer { try? FileManager.default.removeItem(at: folder) }
      let (a, b) = try await LivePhotoPair.prepare(still: image, motion: movie, in: folder)
      let stem = FolderExport.stem(photo.url.deletingPathExtension().lastPathComponent)
      let parts: [FolderExport.File] = [
        .init(source: a, stem: stem, ext: "jpg"), .init(source: b, stem: stem, ext: "mov"),
      ]
      try await FolderGrants.shared.withFolder(choice.id, writing: true) {
        try FolderExport.write(parts, into: $0, group: "实况-" + stem)
      }
    } else {
      try await LivePhotoPair.save(still: image, motion: movie)
    }
  }
}
