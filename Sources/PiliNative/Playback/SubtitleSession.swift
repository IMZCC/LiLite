import Foundation

#if canImport(AVFoundation)
  import AVFoundation
#endif
#if canImport(Combine)
  import Combine
#endif

@MainActor final class SubtitleSession: ObservableObject {
  struct Entry: Identifiable {
    enum Source {
      case service(SubtitleTrack)
      case local(SubtitleDocument)
    }
    let id: String, name: String, language: String, ai: Bool, source: Source
  }
  @Published private(set) var tracks = [Entry]()
  @Published private(set) var first: String?
  @Published private(set) var second: String?
  struct Script: Identifiable { let id: String, data: Data }
  @Published private(set) var scripts = [Script]()
  @Published private(set) var timeline = SubtitleTimeline()
  @Published var issue: String?
  private(set) var epoch = UUID()
  private var remote = [String: SubtitleDocument](), recent = [String](), stamp = UUID(),
    selectTask: Task<Void, Never>?
  private var authorize: (@MainActor () async throws -> Void)?
  private var modified = false, importBytes = 0
  func reset() {
    epoch = UUID()
    stamp = UUID()
    selectTask?.cancel()
    selectTask = nil
    tracks = []
    first = nil
    second = nil
    issue = nil
    remote = [:]
    recent = []
    modified = false
    authorize = nil
    importBytes = 0
    scripts = []
    timeline = .init()
  }
  func offer(_ network: [SubtitleTrack], authorize: (@MainActor () async throws -> Void)? = nil)
    async
  {
    self.authorize = authorize
    issue = nil
    remote.removeAll()
    recent.removeAll()
    tracks =
      network.map {
        Entry(id: $0.id, name: $0.lan_doc, language: $0.lan, ai: $0.isAI, source: .service($0))
      }
      + tracks.filter {
        if case .local = $0.source { return true }
        return false
      }
    if modified {
      if let id = first, !tracks.contains(where: { $0.id == id }) {
        first = nil
        second = nil
      }
      if let id = second, !tracks.contains(where: { $0.id == id }) { second = nil }
      await reload()
    } else {
      await chooseDefault()
    }
  }
  func offline(_ stored: [OfflineExtras.Language]) async {
    let epoch = self.epoch
    let work = Task.detached(priority: .userInitiated) {
      var entries = [Entry]()
      for row in stored {
        if Task.isCancelled { return [Entry]() }
        guard let data = try? SubtitleDocument(cues: row.cues) else { continue }
        entries.append(Entry(id: row.id, name: row.name, language: row.language ?? row.id,
          ai: row.ai ?? false, source: .local(data)))
      }
      return entries
    }
    let local = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    guard !Task.isCancelled, self.epoch == epoch else { return }
    let existing = Set(tracks.map(\.id))
    tracks += local.filter { !existing.contains($0.id) }
    await chooseDefault()
  }
  private static var volume: Float {
    #if canImport(AVFoundation)
      AVAudioSession.sharedInstance().outputVolume
    #else
      1
    #endif
  }
  private func chooseDefault() async {
    guard !modified,
      let row = SubtitlePreference.current.select(
        tracks, language: { $0.language }, isAI: { $0.ai }, volume: Self.volume)
    else { return }
    first = row.id
    await reload()
  }
  func select(_ id: String?, secondary: Bool = false) async {
    guard id == nil || tracks.contains(where: { $0.id == id }) else { return }
    modified = true
    if secondary {
      second = id == first ? nil : id
    } else {
      first = id
      if first == second || first == nil { second = nil }
    }
    await reload()
  }
  func add(_ data: SubtitleDocument, name: String, bytes: Int) async throws {
    guard tracks.count < 128, bytes >= 0, importBytes <= 16 * 1024 * 1024 - bytes else {
      throw ServiceError("本次播放加载的字幕文件过多")
    }
    let id = "file:" + UUID().uuidString
    tracks.append(.init(id: id, name: name, language: "", ai: false, source: .local(data)))
    importBytes += bytes
    await select(id)
  }
  func document(_ row: Entry) async throws -> SubtitleDocument {
    switch row.source {
    case .local(let d): return d
    case .service(let item):
      try await authorize?()
      if let d = remote[row.id] { return d }
      let key = epoch
      let d = try await BiliAPI.shared.subtitleDocument(item)
      try Task.checkCancellation()
      try await authorize?()
      guard key == epoch, tracks.contains(where: { $0.id == row.id }) else {
        throw CancellationError()
      }
      remote[row.id] = d
      recent.removeAll { $0 == row.id }
      recent.append(row.id)
      while recent.count > 3 { remote[recent.removeFirst()] = nil }
      return d
    }
  }
  private func reload() async {
    let key = UUID()
    stamp = key
    selectTask?.cancel()
    issue = nil
    scripts = []
    timeline = .init()
    guard let a = tracks.first(where: { $0.id == first }) else { return }
    let b = tracks.first(where: { $0.id == second })
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        let first = try await self.document(a)
        try Task.checkCancellation()
        guard self.stamp == key else { return }
        let primaryCues = first.assPayload == nil ? first.cues : []
        let primary = try await SubtitleTimeline.prepare(primaryCues)
        guard self.stamp == key, !Task.isCancelled else { return }
        if let bytes = first.assPayload { self.scripts = [Script(id: a.id, data: bytes)] }
        self.timeline = primary
        if let b {
          let supplement = try await self.document(b)
          try Task.checkCancellation()
          let combined = try await SubtitleTimeline.prepare(primaryCues, supplement.assPayload == nil ? supplement.cues : [])
          if self.stamp == key, !Task.isCancelled {
            if let data = supplement.assPayload { self.scripts.append(.init(id: b.id, data: data)) }
            self.timeline = combined
          }
        }
      } catch {
        if self.stamp == key && !Task.isCancelled { self.issue = error.localizedDescription }
      }
    }
    selectTask = task
    await task.value
  }
}
