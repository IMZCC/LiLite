import AVKit
import CryptoKit
import SwiftUI

private final class DownloadEvents: CertificateSessionDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
  weak var owner: Downloads?
  let directory: URL
  init(directory: URL) { self.directory = directory }
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    guard let key = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
    Task { @MainActor in
      owner?.advance(
        key, task: downloadTask.taskIdentifier, totalBytesWritten, totalBytesExpectedToWrite)
    }
  }
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo temporary: URL
  ) {
    guard let key = downloadTask.taskDescription, let finished = try? SleepExitFence.shared.enter() else { return }
    do {
      guard let h = downloadTask.response as? HTTPURLResponse, [200, 206].contains(h.statusCode)
      else { throw ServiceError("下载服务器拒绝了请求") }
      let size = (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
      guard size > 0, h.expectedContentLength < 0 || h.expectedContentLength == Int64(size) else {
        throw ServiceError("媒体文件不完整")
      }
      let slice: OfflinePieces.Slice?
      if h.statusCode == 206 {
        guard
          let r = OfflinePieces.Slice(
            range: h.value(forHTTPHeaderField: "Content-Range"),
            requested: downloadTask.originalRequest?.value(forHTTPHeaderField: "Range"),
            expected: h.expectedContentLength, etag: h.value(forHTTPHeaderField: "ETag")),
          r.length == Int64(size)
        else { throw ServiceError("媒体服务器返回的范围不符") }
        slice = r
      } else {
        let part = key.split(separator: "|").last.map(String.init) ?? ""
        try OfflinePieces.requireHeader(temporary, legacy: LegacyMediaComponents.isPart(part)); slice = nil
      }
      let staged = directory.appendingPathComponent(UUID().uuidString + ".incoming")
      try FileManager.default.moveItem(at: temporary, to: staged)
      Task { @MainActor in
        defer { finished() }
        guard let owner else {
          try? FileManager.default.removeItem(at: staged)
          return
        }
        await owner.arrived(key, task: downloadTask.taskIdentifier, staged, slice: slice)
      }
    } catch {
      let message = error.localizedDescription
      Task { @MainActor in
        defer { finished() }
        await owner?.readyIndex()
        owner?.transferFailed(key, task: downloadTask.taskIdentifier, message)
      }
    }
  }
  override func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let error, let key = task.taskDescription, (error as NSError).code != NSURLErrorCancelled
    else { return }
    let message = error.localizedDescription
    Task { @MainActor in
      await owner?.readyIndex()
      owner?.transferFailed(key, task: task.taskIdentifier, message)
    }
  }
  override func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    Task { @MainActor in
      await owner?.readyIndex()
      owner?.finishedEvents()
    }
  }
}
final class DownloadLifecycle: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?
  ) -> UIInterfaceOrientationMask {
    TheaterOrientation.allowed(window)
  }
  @MainActor static var finish: (() -> Void)?
  func application(
    _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    guard identifier == Downloads.sessionID else {
      completionHandler()
      return
    }
    Self.finish = completionHandler
    _ = Downloads.shared
  }
}
@MainActor final class Downloads: ObservableObject {
  static let shared = Downloads()
  static let sessionID = "com.liuliuya.PiliNative.offline.v1"
  @Published private(set) var list: [OfflineVideo] = []
  @Published var progress: [String: Double] = [:]
  @Published var issue: String?
  @Published private(set) var moving = Set<String>()
  private var holdingForExit = false, exitCheckpointFailed = false
  private var heldTasks = [String: Int]()
  private var exitJournal: URL { directory.appendingPathComponent("sleep-hold.json") }
  private func saveExitJournal() throws {
    try JSONEncoder().encode(heldTasks).write(to: exitJournal, options: .atomic)
  }
  private func releaseExitTransfers(_ tasks: [URLSessionTask], owner: String) {
    guard !holdingForExit, let data = try? Data(contentsOf: exitJournal),
      let saved = try? JSONDecoder().decode([String:Int].self, from: data) else { return }
    for t in tasks {
      guard let key = t.taskDescription, let (i, _) = lookup(key),
        SleepTransferHold.mayResume(saved, key: key, task: t.taskIdentifier, suspended: t.state == .suspended,
          transferring: list[i].phase == .transferring, downloadOwner: list[i].cacheOwner, currentOwner: owner)
      else { continue }
      t.resume()
    }
    heldTasks.removeAll()
    try? FileManager.default.removeItem(at: exitJournal)
  }
  func checkpointForExit() async throws {
    await readyIndex()
    guard !indexUnavailable else { throw ServiceError("缓存清单不可用，已取消退出") }
    holdingForExit = true
    exitCheckpointFailed = false
    let tasks = await session.allTasks
    try Task.checkCancellation()
    let running = tasks.filter { $0.state == .running && $0.taskDescription != nil }
    for t in running { if let key = t.taskDescription { heldTasks[key] = t.taskIdentifier } }
    try saveExitJournal()
    for t in running { t.suspend() }
    // Earlier background completions must hand off their temporary files before sealing.
    await withCheckedContinuation { (next: CheckedContinuation<Void, Never>) in
      session.delegateQueue.addBarrierBlock { next.resume() }
    }
    while !ingesting.isEmpty || !moving.isEmpty || !removingTokens.isEmpty
      || !renewing.isEmpty || !extraTasks.isEmpty || !finalizing.isEmpty {
      try await Task.sleep(for: .milliseconds(150))
    }
    try Task.checkCancellation()
    guard holdingForExit && !exitCheckpointFailed else { throw ServiceError("未能保存下载进度，已取消退出") }
    try await persistIndex()
  }
  func releaseExitCheckpoint() async {
    guard holdingForExit else { return }
    holdingForExit = false
    let uid = (try? await AccountJar.shared.current(.role(.video)))?.id ?? ""
    releaseExitTransfers(await session.allTasks, owner: uid)
  }
  private var removingTokens = Set<String>()
  private var foregroundObserver: NSObjectProtocol?
  private static var playbackLeaseKey: UInt8 = 0
  let directory: URL
  private let events: DownloadEvents
  private var session: URLSession!
  private var metrics: [String: (Int64, Int64)] = [:]
  private struct Attempt { let task: URLSessionDownloadTask, remaining: ArraySlice<URL>, ref: URL }
  private var attempts: [String: Attempt] = [:]
  private func pieces(_ row: OfflineVideo, _ component: String) -> OfflinePieces {
    OfflinePieces(
      base: directory.appendingPathComponent(row.id + "." + component),
      identity: row.mediaIdentity?[component] ?? "", legacy: LegacyMediaComponents.isPart(component))
  }
  private var ingesting = Set<String>()
  private func readyPieces(_ row: OfflineVideo, _ p: String, total: Int64) throws {
    let work = pieces(row, p)
    guard !FileManager.default.fileExists(atPath: file(row, p).path) else {
      try work.clear(); return
    }
    guard try OfflinePackage.size(work.partial) == total else {
      try work.clear(); throw ServiceError("缓存轨道长度发生变化")
    }; try OfflinePieces.requireHeader(work.partial, legacy: LegacyMediaComponents.isPart(p))
    try FileManager.default.moveItem(at: work.partial, to: file(row, p)); try work.clear()
  }
  @Published private(set) var indexUnavailable = false
  private var index: URL { directory.appendingPathComponent("index.json") }
  private var indexRead: Task<OfflineIndexStore.Result, Error>?
  private var indexGeneration = UUID()
  private var indexWrite: Task<Void, Error>?
  private var pendingIndexWrites = 0
  private var needsIndexRewrite = false
  private init() {
    directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Offline", isDirectory: true)
    events = DownloadEvents(directory: directory)
    events.owner = self
    beginIndexRead()
    let c = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
    c.sessionSendsLaunchEvents = true
    c.isDiscretionary = false
    c.urlCredentialStorage = nil
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    session = URLSession(configuration: c, delegate: events, delegateQueue: nil)
    foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in await self?.retryStorage() }
    }
    Task { await readyIndex(); await reconcile(list) }
  }
  private func beginIndexRead() {
    let directory = directory, index = index
    let previousWrite = indexWrite
    indexUnavailable = true; indexGeneration = UUID()
    indexRead = Task.detached(priority: .utility) {
      if let previousWrite { _ = try? await previousWrite.value }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      var dir = directory, flags = URLResourceValues()
      flags.isExcludedFromBackup = true
      try dir.setResourceValues(flags)
      let result = try OfflineIndexStore.load(index)
      var seen = Set<String>()
      let rows = result.rows.filter { Self.valid($0) && seen.insert($0.id).inserted }
      return .init(rows: rows, recovered: result.recovered || rows.count != result.rows.count)
    }
  }
  fileprivate func readyIndex() async {
    guard let pending = indexRead else { return }
    let generation = indexGeneration
    do {
      let result = try await pending.value
      guard indexRead != nil, indexGeneration == generation else { return }
      list = result.rows; indexUnavailable = false; indexRead = nil
      needsIndexRewrite = result.recovered
      if result.recovered { issue = "已恢复本机缓存清单" }
    } catch {
      guard indexGeneration == generation else { return }
      indexRead = nil; indexUnavailable = true; issue = error.localizedDescription
    }
  }
  func retryIndex() async {
    if indexRead == nil { beginIndexRead() }
    await readyIndex()
    await reconcile(list)
  }
  nonisolated private static func valid(_ v: OfflineVideo) -> Bool {
    v.validScope && v.cid > 0
      && v.bvid.range(of: "^BV[0-9A-Za-z]{10}$", options: .regularExpression) != nil
      && Set(v.components).count == v.components.count && !v.components.isEmpty
      && (v.legacyMedia || v.components.allSatisfy { ["movie", "video", "audio"].contains($0) })
  }
  func file(_ v: OfflineVideo, _ c: String) -> URL {
    OfflineMediaStore.local(v, c, app: directory)
  }
  private func lookup(_ key: String) -> (Int, String)? {
    let id = key.split(separator: "|", maxSplits: 1).first.map(String.init) ?? key
    guard let i = list.firstIndex(where: { $0.id == id }),
      let component = list[i].components.first(where: { list[i].key($0) == key })
    else { return nil }
    guard !removingTokens.contains(list[i].token) else { return nil }
    return (i, component)
  }
  private func enqueueIndexWrite() throws -> Task<Void, Error> {
    guard !indexUnavailable else { throw ServiceError("缓存清单不可用，请重新读取") }
    let finished = try SleepExitFence.shared.enter()
    let rows = list, url = index, previous = indexWrite
    // Submission is ordered on MainActor; encoding and both atomic file writes are off-main.
    let write = Task.detached(priority: .utility) {
      defer { finished() }
      if let previous { _ = try? await previous.value }
      try OfflineIndexStore.save(rows, url)
    }
    indexWrite = write; pendingIndexWrites += 1
    Task {
      do { try await write.value } catch {
        issue = error.localizedDescription
        if holdingForExit { exitCheckpointFailed = true }
      }
      pendingIndexWrites -= 1
      finishBackgroundIfReady()
    }
    return write
  }
  private func persistIndex() async throws {
    try await enqueueIndexWrite().value
  }
  private func save() {
    do { _ = try enqueueIndexWrite() } catch {
      issue = error.localizedDescription
    }
  }
  private func reconcile(_ restored: [OfflineVideo]) async {
    guard let finished = try? SleepExitFence.shared.enter() else { return }; defer { finished() }
    guard !indexUnavailable else { return }
    let observed = Dictionary(
      uniqueKeysWithValues: restored.map { ($0.id, $0.generation?.uuidString ?? "") })
    let tasks = await session.allTasks
    let owner = (try? await AccountJar.shared.current(.role(.video)))?.id ?? ""
    releaseExitTransfers(tasks, owner: owner)
    let active = Set(tasks.compactMap(\.taskDescription))
    let snapshot = list, directory = directory
    let files = await Task.detached(priority: .utility) {
      var result = [String: (missing: [String], bytes: Int64)]()
      for row in snapshot where row.location == .app {
        let urls = row.components.map { ($0, OfflineMediaStore.local(row, $0, app: directory)) }
        result[row.token] = (
          urls.filter { !FileManager.default.fileExists(atPath: $0.1.path) }.map(\.0),
          urls.compactMap { try? OfflinePackage.size($0.1) }.reduce(0, +))
      }
      return result
    }.value
    var interrupted = [OfflineVideo]()
    var changed = needsIndexRewrite
    for v in list {
      guard let i = list.firstIndex(where: { $0.token == v.token }) else { continue }
      guard observed[v.id] == (v.generation?.uuidString ?? "") else { continue }
      if v.location != .app { continue }
      guard let disk = files[v.token] else { continue }
      let missing = disk.missing
      if missing.isEmpty, v.legacyMedia {
        guard finalizing.insert(v.token).inserted else { continue }
        defer { finalizing.remove(v.token); finishBackgroundIfReady() }
        do {
          guard (try await AccountJar.shared.localOwner(.role(.video)) ?? "") == v.cacheOwner else { continue }
          for part in v.components { try await LegacyOfflineMedia.prepare(file(v, part)) }
          guard list.indices.contains(i), list[i].token == v.token else { continue }
        } catch {
          guard list.indices.contains(i), list[i].token == v.token else { continue }
          list[i].phase = .failed; list[i].error = error.localizedDescription
          changed = true
          continue
        }
      }
      if v.phase == .queued {
        changed = true
        list[i].phase = .failed
        list[i].error = "下载已中断"
        if v.phase != .paused { interrupted.append(list[i]) }
      } else if missing.isEmpty && v.phase != .failed {
        if list[i].mediaBytes != disk.bytes || list[i].phase != .saved || list[i].error != nil {
          list[i].mediaBytes = disk.bytes; list[i].phase = .saved; list[i].error = nil
          changed = true
        }
      } else if v.phase == .saved && !missing.isEmpty {
        changed = true
        list[i].phase = .failed
        list[i].error = "缓存文件缺失，请重试"
      } else if v.phase == .transferring
        && !missing.allSatisfy({ active.contains(v.key($0)) })
      {
        changed = true
        list[i].phase = .failed
        list[i].error = "下载已中断"
        if v.phase != .paused { interrupted.append(list[i]) }
      }
    }
    if changed { save(); needsIndexRewrite = false }
    let uid = (try? await AccountJar.shared.current(.role(.video)))?.id ?? ""
    for row in interrupted
    where row.cacheOwner == uid
      && list.contains(where: { $0.token == row.token && $0.phase == .failed })
    { await start(row) }
    for row in list where row.cacheOwner == uid && row.phase == .saved && row.attachmentStamp == nil {
      Task { await refreshExtras(row, mode: row.includeExtras == true ? .all : .minimal) }
    }
    await retryStorage()
  }
  func existing(_ v: OfflineVideo, owner: String) -> OfflineVideo? {
    list.first {
      $0.bvid == v.bvid && $0.cid == v.cid && $0.episode == v.episode && $0.cacheOwner == owner
    }
  }
  func add(
    _ video: Video, cid: Int64, quality: Int? = nil, audioQuality: Int? = nil, owner: String,
    extras: Bool = true, singleFile: Bool = false,
    collection: (id: Int64, title: String, order: Int)? = nil
  ) async -> String? {
    let part = video.pages?.first(where: { $0.cid == cid })?.part ?? ""
    var v = OfflineVideo(bvid: video.bvid, cid: cid, title: video.title, part: part)
    v.quality = quality
    v.audioQuality = audioQuality; v.cacheOwner = owner; v.scoped = true; v.cover = video.pic
    v.pageOrder = video.pages?.firstIndex(where: { $0.cid == cid }).map { $0 + 1 }
    v.singleFile = singleFile
    if let collection {
      v.seriesID = "ugc:" + String(collection.id); v.collectionTitle = collection.title;
      v.pageOrder = collection.order
    }
    v.aid = video.aid
    v.seconds =
      video.pages?.first(where: { $0.cid == cid })?.duration
      ?? (video.pages?.count ?? 0 <= 1 ? video.duration : nil)
    v.includeExtras = extras
    await start(v)
    guard let created = existing(v, owner: owner) else { return issue ?? "未能添加缓存" }
    return created.phase == .failed ? (created.error ?? "未能添加缓存") : nil
  }
  func renewLegacy(_ old: OfflineVideo) async {
    guard let done = try? SleepExitFence.shared.enter() else { return }; defer { done() }
    guard old.cacheOwner == nil, old.episode == nil, list.contains(where: { $0.token == old.token })
    else { return }
    do {
      let uid = try await AccountJar.shared.current(.role(.video))?.id ?? ""
      var fresh = OfflineVideo(bvid: old.bvid, cid: old.cid, title: old.title, part: old.part)
      fresh.scoped = true; fresh.cacheOwner = uid; fresh.aid = old.aid; fresh.quality = old.quality;
      fresh.audioQuality = old.audioQuality
      fresh.seconds = old.seconds; fresh.pageOrder = old.pageOrder;
      fresh.includeExtras = old.includeExtras; fresh.cover = old.cover
      await start(fresh)
    } catch { issue = error.localizedDescription }
  }
  private struct Plan {
    let row: OfflineVideo, ref: URL, streams: [(String, [URL])], identity: [String: String]
  }
  private func resolve(_ v: OfflineVideo, forceMovie: Bool) async throws -> Plan {
    var row = v
    guard let pinned = v.cacheOwner,
      (try await AccountJar.shared.current(.role(.video))?.id ?? "") == pinned
    else { throw ServiceError("请切换到缓存使用的视频账号") }
    if v.episode == nil {
      let meta = try await BiliAPI.shared.offlineArchiveDetails(v.bvid, owner: pinned);
      try meta.authorize(v.bvid, cid: v.cid)
      row.uploader = meta.owner?.name ?? v.uploader; row.cover = meta.pic ?? v.cover
    }
    let ref = v.episode?.page ?? URL(string: "https://www.bilibili.com/video/" + v.bvid + "/")!
    var streams: [(String, [URL])] = []
    var identity: [String: String] = [:]
    func tag(_ stream: DashStream) -> String {
      let source = stream.originals.first?.path(percentEncoded: true) ?? ""
      let fields = [
        source, String(stream.id), stream.codecs, String(stream.bandwidth),
        stream.SegmentBase.Initialization, stream.SegmentBase.indexRange,
      ]
      return SHA256.hash(data: Data(fields.joined(separator: "|").utf8)).map {
        String(format: "%02x", $0)
      }.joined()
    }
    func legacy(_ body: LegacyDURLBody) throws -> Plan {
      guard v.audioQuality == nil else { throw ServiceError("此视频的音视频保存在同一片段中") }
      guard v.quality == nil || v.quality == body.quality else { throw ServiceError("所选画质已不可用") }
      let parts = try body.parts
      row.audioMeasurements = body.volume; row.quality = body.quality; row.audioQuality = nil
      row.legacyDurations = parts.map { ($0.length ?? 0) / 1000 }
      for (n, part) in parts.enumerated() {
        let key = LegacyMediaComponents.component(n)
        streams.append((key, part.routes))
        let descriptor = [part.routes.first?.path(percentEncoded: true) ?? "", String(n), String(part.length ?? 0), String(body.quality ?? 0)].joined(separator: "|")
        identity[key] = SHA256.hash(data: Data(descriptor.utf8)).map { String(format: "%02x", $0) }.joined()
      }
      return .init(row: row, ref: ref, streams: streams, identity: identity)
    }
    if v.episode == nil, v.audioQuality == nil, v.singleFile == true || forceMovie {
      let src = try await BiliAPI.shared.legacyPlayback(v.bvid, cid: v.cid, quality: v.quality ?? 64,
        expectedAccount: pinned, forCache: true, preferMP4: true)
      return try legacy(src.body)
    } else {
      let d: DashFormats
      if let e = v.episode {
        guard let owner = v.cacheOwner else { throw ServiceError("请重新添加此分集") }
        let plan = try await BiliAPI.shared.cacheEpisode(
          e, cid: v.cid, bvid: v.bvid, owner: owner, quality: v.quality ?? 127)
        row.seriesID = plan.seriesKey
        row.title = plan.title ?? v.title
        row.uploader = plan.uploader
        row.pageOrder = plan.order
        row.seconds = plan.seconds
        row.episodeClips = plan.clips
        if let body = plan.legacy { return try legacy(body) }
        guard let formats = plan.formats else { throw ServiceError("没有可缓存的视频") }
        d = formats
      } else {
        do {
          d = try await BiliAPI.shared.formats(v.bvid, cid: v.cid, expectedAccount: pinned, forCache: true)
        } catch let error as ServiceError where error.message == "这个视频没有分轨播放地址" {
          let granted = try await BiliAPI.shared.legacyPlayback(v.bvid, cid: v.cid,
            quality: v.quality ?? 127, expectedAccount: pinned, forCache: true)
          return try legacy(granted.body)
        }
      }
      row.audioMeasurements = d.volume
      let qualities = Array(Set(d.video.filter(PlaybackOption.supportsOfflineVideo).map(\.id)))
      if let selected = v.quality, !qualities.contains(selected) {
        throw ServiceError("所选画质当前不可用，请重新选择")
      }
      let q = v.quality ?? OfflineQuality.video(qualities)
      guard let stream = PlaybackOption.chooseOfflineVideo(d.video.filter { $0.id == q }),
        !stream.routes(audio: false).isEmpty
      else { throw ServiceError("所选画质没有可缓存的视频") }
      streams = [("video", stream.routes(audio: false))]
      identity["video"] = tag(stream)
      row.quality = q
      let tracks = (d.audio ?? []).filter { v.audioQuality == nil || $0.id == v.audioQuality }
      let supportedAudio = tracks.filter(PlaybackOption.supportsAudio)
      if let id = OfflineQuality.audio(supportedAudio.map(\.id)),
        let audio = supportedAudio.first(where: { $0.id == id }), !audio.routes(audio: true).isEmpty {
        streams.append(("audio", audio.routes(audio: true)))
        identity["audio"] = tag(audio)
        row.audioQuality = audio.id
      } else if d.advertisedAudio || v.audioQuality != nil {
        throw ServiceError("此音轨暂不支持离线播放")
      }
    }
    return .init(row: row, ref: ref, streams: streams, identity: identity)
  }
  func start(_ v: OfflineVideo) async {
    await readyIndex()
    guard let finished = try? SleepExitFence.shared.enter() else { return }; defer { finished() }
    guard !indexUnavailable else { issue = "请先恢复本机缓存清单"; return }
    guard Self.valid(v) else {
      issue = "视频编号无效"
      return
    }
    guard let owner = v.cacheOwner else { issue = "旧缓存未记录视频账号，请重新取得授权"; return }
    do {
      guard (try await AccountJar.shared.current(.role(.video))?.id ?? "") == owner else {
        throw ServiceError("视频账号已切换")
      }
    } catch { issue = error.localizedDescription; return }
    if let match = existing(v, owner: owner), match.id != v.id {
      if match.phase == .failed { await start(match) }; return
    }
    let previous = list.first(where: { $0.id == v.id })
    if let previous, previous.phase != .failed { return }
    var row = v
    row.phase = .queued
    row.storageIssue = nil
    row.error = nil
    row.generation = UUID()
    row.renewedComponents = nil; row.fullTracks = nil
    // Keep the descriptors of verified files while re-authorizing a failed download.
    if let previous {
      row.streams = previous.streams
      row.mediaIdentity =
        previous.episode == v.episode && previous.cacheOwner == v.cacheOwner
        ? previous.mediaIdentity : nil
      list.removeAll { $0.id == v.id }
      for component in previous.components {
        attempts[previous.key(component)] = nil
        metrics[previous.key(component)] = nil
      }
    }
    list.insert(row, at: 0)
    progress[row.id] = nil
    save()
    let generation = row.generation
    if let previous {
      let keys = Set(previous.components.map { previous.key($0) })
      for t in await session.allTasks where keys.contains(t.taskDescription ?? "") { t.cancel() }
    }
    do {
      if row.moveTo == nil, let destination = try await FolderGrants.shared.current(.cache) {
        row.moveTo = .folder(destination.id)
      }
      let plan = try await resolve(
        row, forceMovie: previous?.components == ["movie"] && v.streams == ["movie"])
      row = plan.row
      let ref = plan.ref
      let streams = plan.streams
      let identity = plan.identity
      try await OfflineExtras.authorize(row)
      guard
        let i = list.firstIndex(where: {
          $0.id == v.id && $0.generation == generation && $0.phase == .queued
        })
      else { return }
      let sameOwner = previous?.episode == v.episode && previous?.cacheOwner == owner
      // Only reuse complete tracks from the same authorized plan with the same representation.
      // Signed URLs and account cookies are never written into the offline index.
      let reusable = Set(
        streams.compactMap { part, _ -> String? in
          guard sameOwner, let tag = identity[part], previous?.mediaIdentity?[part] == tag,
            FileManager.default.fileExists(atPath: file(row, part).path)
          else { return nil }
          return part
        })
      for part in Set(["movie", "video", "audio"] + (previous?.components ?? []) + streams.map(\.0)) where !reusable.contains(part) {
        let f = file(row, part)
        if FileManager.default.fileExists(atPath: f.path) {
          try FileManager.default.removeItem(at: f)
        }
      }
      row.streams = streams.map(\.0)
      row.mediaIdentity = identity
      row.phase = .transferring
      list[i] = row
      save()
      if streams.allSatisfy({ reusable.contains($0.0) }) { await completeIfReady(row) }
      for (part, urls) in streams where !reusable.contains(part) {
        launch(row.key(part), urls: urls[...], ref: ref, paused: false)
      }
    } catch {
      if let i = list.firstIndex(where: { $0.id == v.id && $0.generation == generation }) {
        list[i].phase = .failed
        list[i].error = error.localizedDescription
        save()
      }
    }
  }
  private func launch(_ key: String, urls: ArraySlice<URL>, ref: URL, paused: Bool) {
    guard let url = urls.first, let (i, part) = lookup(key) else { return }
    let row = list[i]
    var r = URLRequest(url: url)
    if row.mediaIdentity?[part] != nil && !(row.fullTracks ?? []).contains(part) {
      let work = pieces(row, part), state = work.state()
      if let state, state.total == state.committed {
        do { try readyPieces(row, part, total: state.total); Task { await completeIfReady(row) } } catch {
          failed(key, error.localizedDescription)
        }; return
      }
      r.setValue(work.request(state), forHTTPHeaderField: "Range")
      if let state { r.setValue(state.validator, forHTTPHeaderField: "If-Range") }
    }
    r.httpShouldHandleCookies = false
    r.setValue(ref.absoluteString, forHTTPHeaderField: "Referer")
    r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    r.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Safari/604.1",
      forHTTPHeaderField: "User-Agent")
    let t = session.downloadTask(with: r)
    t.taskDescription = key
    attempts[key] = Attempt(task: t, remaining: urls.dropFirst(), ref: ref)
    if !paused {
      if holdingForExit {
        heldTasks[key] = t.taskIdentifier
        do { try saveExitJournal() }
        catch { exitCheckpointFailed = true; issue = error.localizedDescription; t.resume() }
      } else { t.resume() }
    }
  }
  private func matches(_ key: String, _ task: Int) -> Bool {
    attempts[key].map { $0.task.taskIdentifier == task } ?? true  // System-restored background tasks have no in-memory plan.
  }
  fileprivate func advance(_ key: String, task: Int, _ n: Int64, _ total: Int64) {
    guard matches(key, task), let (i, _) = lookup(key), list[i].phase == .transferring else {
      return
    }
    let v = list[i]
    if let p = v.components.first(where: { v.key($0) == key }), let receipt = pieces(v, p).state() {
      metrics[key] = (min(receipt.total, receipt.committed + n), receipt.total)
    } else {
      metrics[key] = (n, total)
    }
    let samples = v.components.compactMap { metrics[v.key($0)] }
    let sum = samples.reduce(0.0) { $0 + Double($1.1) }
    if sum > 0 { progress[v.id] = min(0.999, samples.reduce(0.0) { $0 + Double($1.0) } / sum) }
  }
  private var finalizing = Set<String>()
  private func completeIfReady(_ v: OfflineVideo) async {
    guard let done = try? SleepExitFence.shared.enter() else { return }; defer { done() }
    guard !finalizing.contains(v.token) else { return }
    finalizing.insert(v.token)
    defer { finalizing.remove(v.token); finishBackgroundIfReady() }
    if v.legacyMedia, v.components.allSatisfy({ FileManager.default.fileExists(atPath: file(v, $0).path) }) {
      do {
        for part in v.components {
          guard (try await AccountJar.shared.localOwner(.role(.video)) ?? "") == v.cacheOwner else { throw ServiceError("缓存账号已切换") }
          try await LegacyOfflineMedia.prepare(file(v, part))
        }
        guard (try await AccountJar.shared.localOwner(.role(.video)) ?? "") == v.cacheOwner else { throw ServiceError("缓存账号已切换") }
      } catch { failed(v.key(v.components[0]), error.localizedDescription); return }
    }
    guard let i = list.firstIndex(where: { $0.token == v.token }),
      !removingTokens.contains(v.token),
      v.components.allSatisfy({ FileManager.default.fileExists(atPath: file(v, $0).path) })
    else { return }
    list[i].mediaBytes = v.components.compactMap { try? OfflinePackage.size(file(v, $0)) }.reduce(
      0, +)
    list[i].phase = .saved; list[i].error = nil; progress[v.id] = nil
    for p in v.components { metrics[v.key(p)] = nil }
    save(); let row = list[i];
    Task { await refreshExtras(row, mode: row.includeExtras == true ? .all : .minimal) };
    queueStorage(row)
  }
  fileprivate func arrived(_ key: String, task: Int, _ staged: URL, slice: OfflinePieces.Slice?)
    async
  {
    await readyIndex()
    defer { try? FileManager.default.removeItem(at: staged) }
    guard matches(key, task), let (i, c) = lookup(key), ingesting.insert(key).inserted else {
      return
    }
    defer { ingesting.remove(key); finishBackgroundIfReady() }
    let plan = attempts.removeValue(forKey: key), v = list[i], work = pieces(list[i], c)
    do {
      try await OfflineExtras.authorize(v)
      guard let (j, _) = lookup(key), list[j].token == v.token else { return }
      if let slice {
        let result: OfflinePieces.Advance
        do {
          result = try await OfflinePieceWriter.shared.accept(work, staged, slice: slice)
        } catch OfflinePieces.Failure.changed {
          try await OfflinePieceWriter.shared.clear(work); throw ServiceError("缓存文件版本已变化，请重试")
        }
        try await OfflineExtras.authorize(v)
        guard let (now, _) = lookup(key), list[now].token == v.token else { return }
        switch result {
        case .complete: try readyPieces(v, c, total: slice.total)
        case .whole, .more:
          if case .whole = result {
            list[now].fullTracks = (list[now].fullTracks ?? []) + [c]; save()
          }
          let urls: [URL], reference: URL
          if let plan, let first = plan.task.originalRequest?.url {
            urls = [first] + plan.remaining; reference = plan.ref
          } else {
            let fresh = try await resolve(v, forceMovie: v.components == ["movie"])
            guard fresh.identity[c] == v.mediaIdentity?[c],
              let sources = fresh.streams.first(where: { $0.0 == c })?.1
            else { throw ServiceError("媒体版本已更新") }
            urls = sources; reference = fresh.ref
          }
          guard let (latest, _) = lookup(key), list[latest].token == v.token else { return }
          launch(key, urls: urls[...], ref: reference, paused: list[latest].phase == .paused);
          return
        }
      } else {
        if !FileManager.default.fileExists(atPath: file(v, c).path) {
          try FileManager.default.moveItem(at: staged, to: file(v, c))
        }
        try await OfflinePieceWriter.shared.clear(work)
      }
      await completeIfReady(v)
    } catch { failed(key, error.localizedDescription) }
  }
  fileprivate func transferFailed(_ key: String, task: Int, _ message: String) {
    guard let done = try? SleepExitFence.shared.enter() else { return }; defer { done() }
    guard matches(key, task), let (i, component) = lookup(key),
      !FileManager.default.fileExists(atPath: file(list[i], component).path)
    else { return }
    let plan = attempts.removeValue(forKey: key)
    if let plan, !plan.remaining.isEmpty {
      metrics[key] = nil
      launch(key, urls: plan.remaining, ref: plan.ref, paused: list[i].phase == .paused)
      return
    }
    if list[i].phase != .failed, list[i].phase != .saved,
      !(list[i].renewedComponents ?? []).contains(component)
    {
      let snapshot = list[i]
      list[i].renewedComponents = (list[i].renewedComponents ?? []) + [component]
      renewing.insert(key)
      save()
      Task {
        defer {
          renewing.remove(key)
          finishBackgroundIfReady()
        }
        do {
          let new = try await resolve(snapshot, forceMovie: snapshot.components == ["movie"])
          guard let (j, _) = lookup(key),
            !FileManager.default.fileExists(atPath: file(snapshot, component).path),
            list[j].phase != .saved
          else { return }
          guard let urls = new.streams.first(where: { $0.0 == component })?.1, !urls.isEmpty,
            snapshot.mediaIdentity?[component] != nil
              && snapshot.mediaIdentity?[component] == new.identity[component]
          else { throw ServiceError("媒体版本已更新，请重试缓存") }
          metrics[key] = nil
          launch(key, urls: urls[...], ref: new.ref, paused: list[j].phase == .paused)
        } catch { failed(key, error.localizedDescription) }
      }
      return
    }
    if !renewing.contains(key) { failed(key, message) }
  }
  private var renewing = Set<String>()
  private var backgroundComplete = false
  fileprivate func finishedEvents() {
    backgroundComplete = true
    finishBackgroundIfReady()
  }
  private func finishBackgroundIfReady() {
    guard backgroundComplete, renewing.isEmpty, ingesting.isEmpty, finalizing.isEmpty,
      pendingIndexWrites == 0, indexRead == nil else { return }
    backgroundComplete = false
    DownloadLifecycle.finish?()
    DownloadLifecycle.finish = nil
  }
  private func failed(_ key: String, _ message: String) {
    guard let (i, _) = lookup(key) else { return }
    list[i].phase = .failed
    list[i].error = message
    progress[list[i].id] = nil
    save()
  }
  func suspendOtherOwners(_ owner: String) async {
    await readyIndex()
    guard let done = try? SleepExitFence.shared.enter() else { return }; defer { done() }
    let tasks = await session.allTasks
    guard let active = try? await AccountJar.shared.presentedState().owner(.role(.video)) ?? "",
      active == owner
    else { return }
    var changed = false
    for task in tasks {
      guard let key = task.taskDescription, let (i, _) = lookup(key), list[i].cacheOwner != owner,
        list[i].phase == .transferring || list[i].phase == .paused
      else { continue }; if task.state == .running { task.suspend() }
      if list[i].phase != .paused { list[i].phase = .paused; changed = true }
    }
    for row in list where row.cacheOwner != owner { extraTasks[row.token]?.cancel() }
    if changed { save() }
  }
  func pause(_ v: OfflineVideo, toPaused desired: Bool? = nil) async {
    guard let done = try? SleepExitFence.shared.enter() else { return }; defer { done() }
    let tasks = await session.allTasks
    guard let i = list.firstIndex(where: { $0.id == v.id && $0.generation == v.generation }),
      [OfflineVideo.Phase.transferring, .paused].contains(list[i].phase)
    else { return }
    if let desired, (list[i].phase == .paused) == desired { return }
    let resume = list[i].phase == .paused
    if resume {
      do {
        guard let owner = v.cacheOwner,
          (try await AccountJar.shared.current(.role(.video))?.id ?? "") == owner
        else { throw ServiceError("缓存账号已切换") }
      } catch { issue = error.localizedDescription; return }
    }
    guard let i = list.firstIndex(where: { $0.token == v.token }) else { return }
    let keys = Set(v.components.map { v.key($0) })
    var seen = Set<Int>()
    for t in tasks + keys.compactMap({ attempts[$0]?.task })
    where keys.contains(t.taskDescription ?? "") && seen.insert(t.taskIdentifier).inserted {
      if resume && t.state == .suspended {
        t.resume()
      } else if !resume && t.state == .running {
        t.suspend()
      }
    }
    if resume && seen.isEmpty
      && !keys.contains(where: { renewing.contains($0) || ingesting.contains($0) })
    {
      list[i].phase = .failed; save(); await start(list[i]); return
    }
    list[i].phase = resume ? .transferring : .paused
    save()
  }
  func remove(_ v: OfflineVideo) async { await remove([v]) }
  func remove(_ snapshots: [OfflineVideo]) async {
    guard let finished = try? SleepExitFence.shared.enter() else { return }; defer { finished() }
    // A replacement download can have the same BV/CID; delete only the generation the user confirmed.
    guard let viewer = try? await AccountJar.shared.presentedState().owner(.role(.video)) ?? "" else {
      issue = "无法确认当前视频账号"; return
    }
    let tokens = Set(snapshots.filter(Self.valid).map(\.token))
    let selected = list.filter {
      $0.visible(to: viewer) && tokens.contains($0.token) && !moving.contains($0.token) && !removingTokens.contains($0.token) && !finalizing.contains($0.token)
    }
    guard !selected.isEmpty else {
      if !tokens.isEmpty { issue = "正在整理缓存，请稍后重试" }
      return
    }
    removingTokens.formUnion(selected.map(\.token))
    defer { removingTokens.subtract(selected.map(\.token)) }
    var erased = Set<String>()
    for v in selected {
      do {
        // The old provider can be temporarily unavailable. Keep the row until both
        // sides of an interrupted relocation have been removed.
        if let old = v.retire, old != v.location {
          try await OfflineMediaStore.shared.erase(old, row: v, app: directory, expectedOwner: viewer)
        }
        if let pending = v.moveTo, pending != v.location, v.phase == .saved {
          try await OfflineMediaStore.shared.erase(pending, row: v, app: directory, expectedOwner: viewer)
        }
        try await OfflineMediaStore.shared.erase(v.location, row: v, app: directory, expectedOwner: viewer)
        let extra = extraTasks[v.token]
        extra?.cancel()
        await extra?.value
        guard (try await AccountJar.shared.presentedState().owner(.role(.video)) ?? "") == viewer
        else { throw ServiceError("视频账号已切换") }
        extraTasks[v.token] = nil
        let dir = extraDirectory(v)
        if FileManager.default.fileExists(atPath: dir.path) {
          try FileManager.default.removeItem(at: dir)
        }
        progress[v.id] = nil
        erased.insert(v.token)
      } catch {
        let note = "未能移除缓存：" + error.localizedDescription
        issue = note
        if let i = list.firstIndex(where: { $0.token == v.token }) { list[i].storageIssue = note }
      }
    }
    let rows = selected.filter { erased.contains($0.token) }
    for v in rows {
      for p in Set(["movie", "video", "audio"] + v.components) {
        try? await OfflinePieceWriter.shared.clear(pieces(v, p))
      }
      OfflineWatchBook.remove(v.token)
    }
    let taskKeys = Set(rows.flatMap { v in v.components.map { v.key($0) } })
    list.removeAll { erased.contains($0.token) }
    for k in taskKeys {
      metrics[k] = nil
      attempts[k] = nil
    }
    save()
    for t in await session.allTasks where taskKeys.contains(t.taskDescription ?? "") { t.cancel() }
  }
  private var extraTasks: [String: Task<Void, Never>] = [:]
  func extraDirectory(_ v: OfflineVideo) -> URL {
    directory.appendingPathComponent(
      v.id + "." + (v.generation?.uuidString ?? "original") + ".extras", isDirectory: true)
  }
  @discardableResult func refreshExtras(_ v: OfflineVideo, mode: OfflineAttachment = .all) async
    -> Bool
  {
    guard let completed = try? SleepExitFence.shared.enter() else { return false }; defer { completed() }
    if let inFlight = extraTasks[v.token] { await inFlight.value }
    guard !Task.isCancelled, extraTasks[v.token] == nil, !removingTokens.contains(v.token),
      list.contains(where: { $0.token == v.token && $0.phase == .saved })
    else { return false }
    let dir = extraDirectory(v)
    let task = Task { @MainActor in
      defer { extraTasks[v.token] = nil }
      var issues = [String]()
      func attempt(_ kind: String, _ operation: () async throws -> Void) async {
        guard !Task.isCancelled else { return }
        do { try await OfflineExtras.authorize(v); try await operation() } catch {
          if !Task.isCancelled { issues.append(kind + "：" + error.localizedDescription) }
        }
      }
      if mode == .all || mode == .comments {
        await attempt("弹幕") { try await OfflineExtras.updateComments(v, dir: dir) }
      }
      if mode == .all || mode == .captions {
        await attempt("字幕") { try await OfflineExtras.updateCaptions(v, dir: dir) }
      }
      if mode == .all || mode == .minimal || mode == .art {
        await attempt("封面") { try await OfflineExtras.updateCover(v, dir: dir) }
      }
      if mode == .segments
        || ((mode == .all || mode == .minimal) && v.episode == nil
          && UserDefaults.standard.bool(forKey: "sponsor.enabled"))
      {
        await attempt("片段") {
          if let ep = v.episode, let uid = v.cacheOwner {
            let verified = try await BiliAPI.shared.cacheEpisode(
              ep, cid: v.cid, bvid: v.bvid, owner: uid)
            try await OfflineExtras.authorize(v)
            if let j = list.firstIndex(where: { $0.token == v.token }) {
              list[j].episodeClips = verified.clips
            }
          } else {
            try await OfflineExtras.updateMarkers(v, dir: dir)
          }
        }
      }
      guard !Task.isCancelled, !removingTokens.contains(v.token),
        let i = list.firstIndex(where: { $0.token == v.token })
      else { return }
      list[i].attachmentStamp = UUID()
      list[i].extrasIssue = issues.isEmpty ? nil : issues.joined(separator: "；")
      if mode == .all { list[i].includeExtras = true }; save()
    }
    extraTasks[v.token] = task
    await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    return !Task.isCancelled
      && list.contains(where: { $0.token == v.token && $0.extrasIssue == nil })
  }
  private func queueStorage(_ row: OfflineVideo) {
    guard UIApplication.shared.applicationState == .active, row.moveTo != nil || row.retire != nil
    else { return }
    Task { await relocate(row.token) }
  }
  func retryStorage() async {
    await readyIndex()
    guard UIApplication.shared.applicationState == .active else { return }
    guard let uid = try? await AccountJar.shared.presentedState().owner(.role(.video)) ?? "" else {
      return
    }
    for row in list
    where row.cacheOwner == uid && row.phase == .saved && (row.moveTo != nil || row.retire != nil) {
      await relocate(row.token)
    }
  }
  func moveSaved(to target: OfflinePlace) async {
    guard let done = try? SleepExitFence.shared.enter() else { return }; defer { done() }
    // A previous move may have copied the package before suspension. Confirm cleanup before
    // replacing its plan; otherwise reselecting a folder could orphan that verified copy.
    guard let uid = try? await AccountJar.shared.presentedState().owner(.role(.video)) ?? "" else {
      return
    }
    for snapshot in list where snapshot.cacheOwner == uid && snapshot.phase == .saved {
      let token = snapshot.token
      guard !removingTokens.contains(token), moving.insert(token).inserted else { continue }
      do {
        try await OfflineExtras.authorize(snapshot)
        if let old = snapshot.retire {
          if target == old, let proof = snapshot.retirementHashes {
            // An unplugged destination must not prevent returning to the still-intact previous copy.
            let hashes = try await OfflineMediaStore.shared.hashes(at: old, row: snapshot, app: directory)
            try OfflinePackage.requireAuthority(hashes, proof: proof, components: snapshot.components)
            try await OfflineExtras.authorize(snapshot)
            guard let i = list.firstIndex(where: { $0.token == token }) else { moving.remove(token); continue }
            list[i].storedAt = old; list[i].retire = snapshot.location
            list[i].moveTo = nil; list[i].storageIssue = nil
            do { try await persistIndex() } catch {
              if let current = list.firstIndex(where: { $0.token == token }) { list[current] = snapshot }
              throw error
            }
            moving.remove(token)
            continue
          }
          try await OfflineMediaStore.shared.retire(old, row: snapshot, app: directory)
        }
        if let pending = snapshot.moveTo, pending != target, pending != snapshot.location {
          try await OfflineMediaStore.shared.retire(pending, row: snapshot, app: directory)
        }
        guard let i = list.firstIndex(where: { $0.token == token }) else {
          moving.remove(token)
          continue
        }
        list[i].retire = nil
        list[i].retirementHashes = nil
        list[i].storageIssue = nil
        list[i].moveTo = list[i].location == target ? nil : target
        try await persistIndex()
      } catch {
        if let i = list.firstIndex(where: { $0.token == token }) {
          list[i].storageIssue = error.localizedDescription
          save()
        }
      }
      moving.remove(token)
    }
    await retryStorage()
  }
  private func relocate(_ token: String) async {
    guard let finished = try? SleepExitFence.shared.enter() else { return }; defer { finished() }
    guard let first = list.firstIndex(where: { $0.token == token }), list[first].phase == .saved,
      !removingTokens.contains(token), moving.insert(token).inserted
    else { return }
    defer { moving.remove(token) }
    do {
      if let old = list[first].retire {
        let row = list[first]
        try await OfflineMediaStore.shared.retire(old, row: row, app: directory)
        guard let i = list.firstIndex(where: { $0.token == token }) else { return }
        list[i].retire = nil
        list[i].retirementHashes = nil
        list[i].storageIssue = nil
        try await persistIndex()
      }
      guard let i = list.firstIndex(where: { $0.token == token }), let target = list[i].moveTo
      else { return }
      let row = list[i]
      try await OfflineExtras.authorize(row)
      let original = row.location
      guard target != original else {
        guard let current = list.firstIndex(where: { $0.token == token }) else { return }
        list[current].moveTo = nil
        try await persistIndex()
        return
      }
      let proof = try await OfflineMediaStore.shared.copy(row, to: target, app: directory)
      guard let j = list.firstIndex(where: { $0.token == token }), list[j].moveTo == target else {
        return
      }
      list[j].storedAt = target
      list[j].retire = original
      list[j].retirementHashes = proof
      list[j].moveTo = nil
      list[j].storageIssue = nil
      // Never erase the only authoritative file until the local index durably points at its verified replacement.
      do { try await persistIndex() } catch {
        if let current = list.firstIndex(where: { $0.token == token }) { list[current] = row }
        throw error
      }
      guard let current = list.first(where: { $0.token == token }) else { return }
      try await OfflineMediaStore.shared.retire(original, row: current, app: directory)
      guard let k = list.firstIndex(where: { $0.token == token }) else { return }
      list[k].retire = nil
      list[k].retirementHashes = nil
      try await persistIndex()
    } catch {
      if let i = list.firstIndex(where: { $0.token == token }) {
        list[i].storageIssue =
          (list[i].retire == nil ? "等待移动：" : "等待清理原位置：") + error.localizedDescription
        save()
      }
    }
  }
  func storageUsage() async -> ([OfflinePlace: Int64], Set<OfflinePlace>) {
    guard let uid = try? await AccountJar.shared.presentedState().owner(.role(.video)) ?? "" else {
      return ([:], [])
    }
    let snapshot = list.filter { $0.visible(to: uid) }
    var sizes: [OfflinePlace: Int64] = [:]
    var unavailable = Set<OfflinePlace>()
    for row in snapshot {
      if Task.isCancelled { break }
      for place in Set([row.location, row.retire, row.moveTo].compactMap { $0 }) {
        do {
          sizes[place, default: 0] += try await OfflineMediaStore.shared.size(
            place, row: row, app: directory)
        } catch { unavailable.insert(place) }
      }
      if row.phase != .saved {
        for c in row.components {
          if let size = try? OfflinePackage.size(pieces(row, c).partial) {
            sizes[.app, default: 0] += size
          }
        }
      }
      let aux = await OfflineMediaStore.shared.extrasSize(extraDirectory(row))
      if aux > 0 { sizes[.app, default: 0] += aux }
    }
    return (sizes, unavailable)
  }
  func playerItem(_ v: OfflineVideo) async throws -> AVPlayerItem {
    guard Self.valid(v), v.phase == .saved else { throw ServiceError("媒体未就绪") }
    do {
      guard let owner = v.cacheOwner,
        (try await AccountJar.shared.localOwner(.role(.video)) ?? "") == owner
      else { throw ServiceError("请切换到缓存这集时使用的视频账号") }
    }
    guard let current = list.first(where: { $0.token == v.token }),
      !removingTokens.contains(v.token)
    else { throw ServiceError("缓存已移除") }
    let lease = try await OfflineMediaStore.shared.files(current, app: directory, pinLocal: true)
    try Task.checkCancellation()
    do {
      guard let owner = v.cacheOwner,
        (try await AccountJar.shared.localOwner(.role(.video)) ?? "") == owner
      else { throw ServiceError("视频账号已切换") }
    }
    func pinned(_ item: AVPlayerItem) -> AVPlayerItem {
      objc_setAssociatedObject(
        item, &Self.playbackLeaseKey, lease, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
      return item
    }
    func checked(_ item: AVPlayerItem) async throws -> AVPlayerItem {
      try Task.checkCancellation()
      do {
        guard let owner = v.cacheOwner, (try await AccountJar.shared.localOwner(.role(.video)) ?? "") == owner
        else { throw ServiceError("视频账号已切换") }
      }
      guard list.contains(where: { $0.token == v.token }), !removingTokens.contains(v.token) else {
        throw ServiceError("缓存已移除")
      }
      return pinned(item)
    }
    if v.legacyMedia {
      return try await checked(OfflineDecoderItem.legacyItem(lease: lease, row: v))
    }
    if let decoded = try await OfflineDecoderItem.item(
      lease: lease, quality: v.quality, owner: v.cacheOwner, volume: v.audioMeasurements)
    {
      return try await checked(decoded)
    }
    if v.components == ["movie"], let url = lease.files["movie"] {
      return try await checked(AVPlayerItem(url: url))
    }
    let composition = AVMutableComposition()
    for (part, kind) in [("video", AVMediaType.video), ("audio", AVMediaType.audio)]
    where v.components.contains(part) {
      guard let u = lease.files[part] else { throw ServiceError("离线轨道不存在") }
      let asset = AVURLAsset(url: u)
      guard let source = try await asset.loadTracks(withMediaType: kind).first,
        let track = composition.addMutableTrack(
          withMediaType: kind, preferredTrackID: kCMPersistentTrackID_Invalid)
      else { throw ServiceError("离线轨道无法读取") }
      let range = try await source.load(.timeRange)
      try track.insertTimeRange(range, of: source, at: .zero)
      if kind == .video { track.preferredTransform = try await source.load(.preferredTransform) }
    }
    return try await checked(AVPlayerItem(asset: composition))
  }
}
