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
  private struct Connection {
    let session: URLSession
    let transfer: ArtworkTransfer
  }
  private static func session(_ cache: URLCache?) -> Connection {
    let config = cache == nil ? URLSessionConfiguration.ephemeral : URLSessionConfiguration.default
    APIProxy.current().apply(to: config)
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCredentialStorage = nil
    config.urlCache = cache
    config.requestCachePolicy =
      cache == nil ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
    let transfer = ArtworkTransfer(publicArtwork: cache != nil)
    return Connection(session: URLSession(configuration: config, delegate: transfer, delegateQueue: nil),
      transfer: transfer)
  }
  static func cachedImage(_ url: URL?, pixels: Int, maximum: Int = 16 * ArtworkStore.mib) -> UIImage? {
    // Only admitted public responses are inserted; disabling the cache empties it.
    guard let url else { return nil }
    let requested = min(2048, max(96, pixels))
    let exact = Key(url: url, pixels: requested, maximum: maximum)
    if let hit = memory.decoded.object(forKey: exact.cacheKey) { return hit.image }
    for size in [96, 192, 384, 768, 1536, 2048] where size > requested {
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
      cachedSession.session.finishTasksAndInvalidate()
      privateSession.session.finishTasksAndInvalidate()
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
    cachedSession.session.invalidateAndCancel()
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
  private static func decode(_ url: URL, session connection: Connection, pixels: Int, maximum: Int)
    async throws -> Decoded
  {
    var req = URLRequest(url: url, timeoutInterval: 20)
    req.httpShouldHandleCookies = false
    req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    let (data, http) = try await connection.transfer.read(req, from: connection.session, limit: maximum)
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

/// Decodes artwork ahead of the rows that will show it, one picture at a time at low priority,
/// so a row scrolling in draws its picture in its first frame instead of a placeholder that
/// fades (and renders again) once the image arrives.
actor ArtworkPrefetch {
  static let shared = ArtworkPrefetch()
  private var queue: [(url: URL, pixels: Int)] = []
  private var requested = Set<String>()
  private var running = false
  func prefetch(_ pictures: [String], pixels: Int, quality: Int) async {
    for picture in pictures {
      let key = "\(pixels)|\(quality)|\(picture)"
      guard !requested.contains(key), let cover = httpsURL(picture) else { continue }
      let url = GalleryPicture(cover).display(quality: quality)
      guard ArtworkStore.cachedImage(url, pixels: pixels) == nil else { continue }
      requested.insert(key)
      queue.append((url, pixels))
    }
    if requested.count > 800 { requested.removeAll() }
    // Only the newest requests matter: rows far behind the screen were scrolled past already.
    if queue.count > 16 { queue.removeFirst(queue.count - 16) }
    guard !running, !queue.isEmpty else { return }
    running = true
    defer { running = false }
    while !queue.isEmpty {
      let next = queue.removeFirst()
      _ = try? await ArtworkStore.shared.image(next.url, pixels: next.pixels)
    }
  }
}

/// The size bucket and the running load of one artwork view, unobserved: as `@State` the
/// measured size alone re-rendered every new cell once more before its image could show.
@MainActor private final class ArtworkLoad {
  var pixels: Int?
  var task: Task<Void, Never>?
  var running: (url: URL, pixels: Int)?
  /// A cached image the body draws without a state change, kept here so a cache eviction
  /// cannot blank it on a later render.
  private var kept: (url: URL, image: UIImage)?
  func held(_ url: URL?) -> UIImage? { kept.flatMap { $0.url == url ? $0.image : nil } }
  func hold(_ image: UIImage, for url: URL) { kept = (url, image) }
  func cancel() {
    task?.cancel()
    task = nil
    running = nil
  }
}

struct RemoteArtwork<Content: View>: View {
  let url: URL?, content: (AsyncImagePhase) -> Content
  @Environment(\.displayScale) private var displayScale
  @State private var load = ArtworkLoad()
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
    let current = delivered == url ? phase : .empty
    let cached = current.image == nil
      ? (load.held(url) ?? ArtworkStore.cachedImage(url, pixels: load.pixels ?? 384)) : nil
    content(cached.map { .success(Image(uiImage: $0)) } ?? current)
      .onGeometryChange(for: Int.self) { geometry in
        ArtworkCacheRules.pixels(width: geometry.size.width, height: geometry.size.height, scale: displayScale)
      } action: { pixels in
        load.pixels = pixels
        start()
      }
      .onChange(of: url) { _, _ in start() }
      .onAppear { start() }
      .onDisappear { load.cancel() }
  }
  /// Shows the best cached size at once and otherwise loads it; writes state only when what is
  /// drawn changes (a warm image the body already picked needs no second render).
  private func start() {
    // Do not begin a provisional 384px request before geometry supplies the actual bucket.
    guard let pixels = load.pixels else { return }
    guard let url else { load.cancel(); return }
    if let running = load.running, running.url != url { load.cancel() }
    if delivered == url, phase.image != nil, deliveredPixels >= pixels { return }
    if let warm = ArtworkStore.cachedImage(url, pixels: pixels) {
      // What the body drew before the size was known: the held image or the cache's pick.
      let drawn = delivered == url && phase.image != nil
        ? nil : (load.held(url) ?? ArtworkStore.cachedImage(url, pixels: 384))
      load.hold(warm, for: url)
      // The body already draws this very image: holding it is enough, no second render.
      if drawn !== warm {
        phase = .success(Image(uiImage: warm)); delivered = url; deliveredPixels = pixels
      }
      return
    }
    if let running = load.running, running.url == url, running.pixels >= pixels { return }
    load.task?.cancel()
    load.running = (url, pixels)
    load.task = Task { @MainActor in
      do {
        let result = try await ArtworkStore.shared.image(url, pixels: pixels)
        guard !Task.isCancelled else { return }
        // Fade freshly decoded artwork in instead of letting it pop over the placeholder.
        withAnimation(.easeOut(duration: 0.18)) {
          phase = .success(Image(uiImage: result)); delivered = url; deliveredPixels = pixels
        }
      } catch {
        if !Task.isCancelled, !(delivered == url && phase.image != nil) {
          phase = .failure(error); delivered = url
        }
      }
      if !Task.isCancelled { load.running = nil }
    }
  }
}
