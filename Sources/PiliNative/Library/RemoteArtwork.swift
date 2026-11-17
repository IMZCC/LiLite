import Foundation
import ImageIO
import SwiftUI

actor ArtworkStore {
  static let shared = ArtworkStore()
  static let key = "images.cacheBytes"
  static let mib = 1024 * 1024
  static let maximum = 999_999 * mib
  static let standard = 1024 * mib
  // Lazy actor-isolated setup: evaluating `shared` from a view must not open the disk cache.
  private lazy var cache: URLCache = {
    let limit = Self.limit()
    let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("PiliPublicArtwork", isDirectory: true)
    let value = URLCache(memoryCapacity: min(16 * Self.mib, limit), diskCapacity: limit, directory: folder)
    if limit == 0 { value.removeAllCachedResponses() }
    return value
  }()
  private lazy var cachedSession = Self.session(cache)
  private var activeProxy = APIProxy.current()
  private lazy var privateSession = Self.session(nil)
  private var configured: Int
  private final class CachedImage {
    let image: UIImage, cost: Int
    init(_ image: UIImage, cost: Int) { self.image = image; self.cost = cost }
  }
  private final class WeakImage {
    weak var value: CachedImage?
    init(_ value: CachedImage) { self.value = value }
  }
  // NSCache synchronizes access; read warm images before a lazy row's first frame.
  private final class Memory: @unchecked Sendable {
    let decoded = NSCache<NSString, CachedImage>()
  }
  private static let memory = Memory()
  private var decoded: NSCache<NSString, CachedImage> { Self.memory.decoded }
  private struct Key: Hashable {
    let url: URL, pixels: Int, maximum: Int
    var cacheKey: NSString { (url.absoluteString + "\n\(pixels):\(maximum)") as NSString }
  }
  private struct Decoded {
    let image: UIImage, cost: Int, cacheable: Bool
  }
  private struct Flight {
    let id: UUID, task: Task<Decoded, Error>, publicFile: Bool
    var waiters: Set<UUID>
  }
  private var flights: [Key: Flight] = [:]
  private var cachedImages: [Key: WeakImage] = [:]
  private static func limit() -> Int {
    guard let n = UserDefaults.standard.object(forKey: key) as? NSNumber else { return standard }
    let value = n.doubleValue
    return value.isFinite && value >= 0 && value <= Double(maximum) ? Int(value) : standard
  }
  private static func session(_ cache: URLCache?) -> URLSession {
    let config = cache == nil ? URLSessionConfiguration.ephemeral : URLSessionConfiguration.default
    APIProxy.current().apply(to: config)
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCredentialStorage = nil
    config.urlCache = cache
    config.requestCachePolicy =
      cache == nil ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
    return URLSession(
      configuration: config, delegate: APIRedirectPolicy(publicArtwork: cache != nil),
      delegateQueue: nil)
  }
  static func cachedImage(_ url: URL?, pixels: Int, maximum: Int = 16 * ArtworkStore.mib) -> UIImage? {
    guard let url, limit() > 0, ArtworkCacheRules.publicFile(url) else { return nil }
    let requested = min(2048, max(96, pixels))
    for size in [requested] + [96, 192, 384, 768, 1536, 2048].filter({ $0 > requested }) {
      let key = Key(url: url, pixels: size, maximum: maximum)
      if let hit = memory.decoded.object(forKey: key.cacheKey) { return hit.image }
    }
    return nil
  }
  private init() {
    let limit = Self.limit()
    configured = limit
    Self.memory.decoded.totalCostLimit = min(48 * Self.mib, limit)
    Self.memory.decoded.countLimit = 192
  }
  private func syncLimit() {
    let setting = APIProxy.current()
    if setting != activeProxy {
      cachedSession.finishTasksAndInvalidate()
      privateSession.finishTasksAndInvalidate()
      cachedSession = Self.session(cache)
      privateSession = Self.session(nil)
      activeProxy = setting
    }
    let bytes = Self.limit()
    if configured == bytes { return }
    configured = bytes
    cache.diskCapacity = bytes
    cache.memoryCapacity = min(16 * Self.mib, bytes)
    decoded.totalCostLimit = min(48 * Self.mib, bytes)
    if bytes == 0 { clear() }
  }
  func usage() -> (disk: Int, memory: Int) {
    syncLimit()
    cachedImages = cachedImages.filter { $0.value.value != nil }
    let pixels = cachedImages.values.reduce(0) { $0 + ($1.value?.cost ?? 0) }
    return (cache.currentDiskUsage, cache.currentMemoryUsage + pixels)
  }
  func clear() {
    cachedSession.invalidateAndCancel()
    cache.removeAllCachedResponses()
    decoded.removeAllObjects()
    cachedImages.removeAll()
    for (key, flight) in flights where flight.publicFile {
      flight.task.cancel(); flights[key] = nil
    }
    cachedSession = Self.session(cache)
  }
  func image(_ url: URL, pixels: Int = 2048, maximum: Int = 16 * ArtworkStore.mib) async throws
    -> UIImage
  {
    try Task.checkCancellation()
    guard url.scheme == "https", url.host != nil, url.user == nil,
      url.password == nil, pixels > 0, maximum > 0
    else { throw URLError(.badURL) }
    syncLimit()
    // Cache only ordinary public CDN assets; bypass disk for signed URLs and other origins.
    let publicFile = ArtworkCacheRules.publicFile(url)
    let requested = Key(url: url, pixels: min(2048, max(96, pixels)), maximum: maximum)
    if publicFile && configured > 0, let hit = Self.cachedImage(url, pixels: requested.pixels, maximum: maximum) { return hit }
    // Avatars/covers often appear at several sizes at once. A larger in-flight decode can
    // satisfy a smaller view too, while retaining the same byte limit and cancellation owners.
    let key = flights.keys.filter {
      $0.url == url && $0.maximum == maximum && $0.pixels >= requested.pixels
    }.min { $0.pixels < $1.pixels } ?? requested
    let waiter = UUID()
    let flight: Flight
    if var existing = flights[key] {
      existing.waiters.insert(waiter); flights[key] = existing; flight = existing
    } else {
      let session = publicFile && configured > 0 ? cachedSession : privateSession
      let task = Task.detached(priority: .utility) {
        try await Self.decode(url, session: session, pixels: key.pixels, maximum: maximum)
      }
      flight = Flight(id: UUID(), task: task, publicFile: publicFile, waiters: [waiter])
      flights[key] = flight
    }
    return try await withTaskCancellationHandler {
      do {
        let result = try await flight.task.value
        try Task.checkCancellation()
        guard !flight.task.isCancelled else { throw CancellationError() }
        if flights[key]?.id == flight.id {
          if result.cacheable && publicFile && configured > 0 {
            let entry = CachedImage(result.image, cost: result.cost)
            decoded.setObject(entry, forKey: key.cacheKey, cost: result.cost)
            cachedImages[key] = WeakImage(entry)
            if cachedImages.count > 384 { cachedImages = cachedImages.filter { $0.value.value != nil } }
          }
          flights[key] = nil
        }
        return result.image
      } catch {
        release(waiter, key: key, flight: flight.id)
        throw error
      }
    } onCancel: {
      Task { await self.release(waiter, key: key, flight: flight.id) }
    }
  }
  private func release(_ waiter: UUID, key: Key, flight id: UUID) {
    guard var flight = flights[key], flight.id == id else { return }
    flight.waiters.remove(waiter)
    if flight.waiters.isEmpty { flight.task.cancel(); flights[key] = nil }
    else { flights[key] = flight }
  }
  private static func decode(_ url: URL, session s: URLSession, pixels: Int, maximum: Int)
    async throws -> Decoded
  {
    var req = URLRequest(url: url, timeoutInterval: 20)
    req.httpShouldHandleCookies = false
    req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    let (bytes, response) = try await s.bytes(for: req)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
      response.expectedContentLength <= maximum
    else { throw URLError(.badServerResponse) }
    var data = Data()
    if response.expectedContentLength > 0 {
      data.reserveCapacity(Int(response.expectedContentLength))
    }
    for try await b in bytes {
      guard data.count < maximum else { throw URLError(.dataLengthExceedsMaximum) }
      data.append(b)
    }
    try Task.checkCancellation()
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: pixels,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    else { throw URLError(.cannotDecodeContentData) }
    try Task.checkCancellation()
    return Decoded(
      image: UIImage(cgImage: image), cost: image.bytesPerRow * image.height,
      cacheable: ArtworkCacheRules.admits(
        url: http.url, status: http.statusCode, mime: http.mimeType,
        cookie: http.value(forHTTPHeaderField: "Set-Cookie"),
        control: http.value(forHTTPHeaderField: "Cache-Control")))
  }
}

struct RemoteArtwork<Content: View>: View {
  let url: URL?, content: (AsyncImagePhase) -> Content
  @Environment(\.displayScale) private var displayScale
  @State private var pixels: Int?
  private struct Request: Equatable {
    let url: URL?
    let pixels: Int?
  }
  @State private var delivered: URL?
  @State private var deliveredPixels = 0
  @State private var phase = AsyncImagePhase.empty
  init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
    self.url = url
    self.content = content
  }
  init<A: View, B: View>(
    url: URL?, @ViewBuilder content: @escaping (Image) -> A,
    @ViewBuilder placeholder: @escaping () -> B
  ) where Content == _ConditionalContent<A, B> {
    self.url = url
    @ViewBuilder func render(_ p: AsyncImagePhase) -> Content {
      if let img = p.image { content(img) } else { placeholder() }
    }
    self.content = render
  }
  var body: some View {
    let request = Request(url: url, pixels: pixels)
    let current = delivered == url ? phase : .empty
    let cached = current.image == nil ? ArtworkStore.cachedImage(url, pixels: pixels ?? 384) : nil
    content(cached.map { .success(Image(uiImage: $0)) } ?? current)
      .onGeometryChange(for: Int.self) { geometry in
        ArtworkCacheRules.pixels(width: geometry.size.width, height: geometry.size.height, scale: displayScale)
      } action: { pixels = $0 }
      .task(id: request) {
      // Do not begin a provisional 384px request before geometry supplies the actual bucket.
      guard let pixels = request.pixels, !Task.isCancelled else { return }
      if delivered == url, phase.image != nil, deliveredPixels >= pixels { return }
      if delivered != url { phase = .empty; deliveredPixels = 0 }
      delivered = url
      guard let url else { return }
      if let warm = ArtworkStore.cachedImage(url, pixels: pixels) {
        phase = .success(Image(uiImage: warm)); deliveredPixels = pixels
        return
      }
      do {
        let result = try await ArtworkStore.shared.image(url, pixels: pixels)
        // Fade freshly decoded artwork in instead of letting it pop over the placeholder.
        if !Task.isCancelled {
          withAnimation(.easeOut(duration: 0.18)) { phase = .success(Image(uiImage: result)) }
          deliveredPixels = pixels
        }
      } catch { if !Task.isCancelled && phase.image == nil { phase = .failure(error) } }
    }
  }
}
