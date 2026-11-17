import Foundation

#if canImport(Combine)
  import Combine
#endif

struct PlaylistStart: Identifiable {
  let id = UUID()
  var rowID: String? = nil, page: Int = 1, resume = false, descending = false
}
extension CloudEntry {
  var advancesInQueue: Bool {
    if case .sharedItem(let v) = self { return v.sharedPlayable }
    return queueTarget != nil
  }
}
@MainActor final class CloudPlaybackList: ObservableObject {
  typealias Window = MediaPageWindow<CloudEntry>
  struct Mark: Codable {
    let id: String, page: Int, reverse: Bool, date: Date
    var desc: Bool? = nil, sort: Int? = nil, reportable: Bool? = nil
  }
  let kind: CloudLibraryKind, uid: String, term: String, order: FavoriteSort, viewed: Int,
    ascending: Bool
  let key: String, allowChanges: Bool
  private let defaults: UserDefaults
  @Published var window = Window(identify: { $0.id }, playable: { $0.advancesInQueue })
  var resumeFullscreen = false
  @Published var current: Window.Slot?
  @Published var busy = false
  @Published var issue: String?
  private var epoch = UUID()
  private var cursor: CreatorPlaybackCursor?
  private let reporter = CreatorHistoryReporter()
  init(
    _ kind: CloudLibraryKind, uid: String, term: String, order: FavoriteSort, viewed: Int,
    ascending: Bool, allowChanges: Bool, defaults: UserDefaults = .standard
  ) {
    self.defaults = defaults
    self.allowChanges = allowChanges && !kind.isShared
    self.kind = kind
    self.uid = uid
    self.term = term
    self.order = order
    self.viewed = viewed
    self.ascending = ascending
    key = Self.makeKey(
      kind, uid: uid, term: term, order: order, viewed: viewed, ascending: ascending)
  }
  static func makeKey(
    _ kind: CloudLibraryKind, uid: String, term: String, order: FavoriteSort, viewed: Int,
    ascending: Bool
  ) -> String {
    let raw = "\(uid)|\(kind.storageID)|\(order.rawValue)|\(viewed)|\(ascending)|\(term)"
    return LibraryPlaylistSignature.key(raw)
  }
  static let storage = "library.playlist.marks"
  static func marks(_ defaults: UserDefaults = .standard) -> [String: Mark] {
    defaults.data(forKey: storage).flatMap {
      try? JSONDecoder().decode([String: Mark].self, from: $0)
    } ?? [:]
  }
  func remember() {
    guard PlaybackMemory.enabled, let current else { return }
    var m = Self.marks(defaults)
    m[key] = Mark(
      id: current.item.id, page: current.number, reverse: window.reversed, date: Date(),
      desc: cursor?.descending, sort: cursor?.sort, reportable: cursor?.reportable)
    let latest = m.sorted { $0.value.date > $1.value.date }.prefix(128)
    if let bytes = try? JSONEncoder().encode(
      Dictionary(uniqueKeysWithValues: latest.map { ($0.key, $0.value) }))
    {
      defaults.set(bytes, forKey: Self.storage)
    }
  }
  private func load(_ n: Int, _ token: UUID) async throws {
    guard !window.has(n), n > 0 else { return }
    if let cursor {
      let slice = try await cursor.get(n)
      guard token == epoch, !Task.isCancelled else { throw CancellationError() }
      put(slice)
      return
    }
    let p = try await kind.fetch(
      String(n), query: term, order: order, uid: uid, viewed: viewed, ascending: ascending)
    try Task.checkCancellation()
    guard token == epoch else { throw CancellationError() }
    if let next = p.next, Int(next) != n + 1 { throw ServiceError("播放列表分页无效") }
    if p.next != nil, window.has(n - 1), !p.items.isEmpty,
      Set(p.items.map(\.id)) == Set(window.slots(n - 1).map(\.item.id))
    {
      throw ServiceError("服务没有返回新的播放条目")
    }
    window.put(n, p.items, hasNext: p.next != nil)
  }
  private func put(_ p: CreatorPlaybackCursor.Slice) {
    if !p.prior { window.firstPage(p.number) }
    let rows =
      kind.isShared
      ? p.entries.map(CloudEntry.sharedItem)
      : p.videos.map(CloudEntry.video)
    window.put(p.number, rows, hasNext: p.later)
  }
  private func search(_ id: String, start: Int, token: UUID) async throws -> Window.Slot? {
    let preferred = max(1, start)
    try await load(preferred, token)
    if let match = window.slots(preferred).first(where: {
      $0.item.id == id && $0.item.queueTarget != nil
    }) {
      return match
    }
    var p = 1
    while window.end == nil || p <= window.end! {
      try await load(p, token)
      if let match = window.slots(p).first(where: { $0.item.id == id && $0.item.queueTarget != nil }
      ) {
        return match
      }
      try Task.checkCancellation()
      p += 1
    }
    return nil
  }
  func open(_ start: PlaylistStart) async {
    invalidate()
    current = nil
    cursor = nil
    resumeFullscreen = false
    window = Window(identify: { $0.id }, playable: { $0.advancesInQueue })
    window.reversed = start.descending
    let token = epoch
    busy = true
    issue = nil
    defer { if token == epoch { busy = false } }
    do {
      var target = start.rowID
      var page = start.page
      let mark = start.resume && PlaybackMemory.enabled ? Self.marks(defaults)[key] : nil
      if let mark {
        target = mark.id
        page = mark.page
        window.reversed = mark.reverse
      }
      var openCursor: CreatorPlaybackCursor?
      var oid = target.flatMap(ArchiveNumber.av)
      if case .shared(let id, let owners) = kind {
        guard id > 0, uid == owners.main else { throw ServiceError("播放列表地址无效") }
        if target != nil, oid == nil { throw ServiceError("播放列表中的视频地址无效") }
        openCursor = CreatorPlaybackCursor(
          .shared(id, owners), type: 3, desc: mark?.desc ?? true, sort: 1, reportable: false)
      } else if case .creator(let scope, let hint) = kind, let type = scope.listType(hint) {
        let useServer = start.resume && mark == nil && scope.mayResume(hint)
        if useServer { oid = hint?.resume }
        let desc =
          mark?.desc ?? (useServer ? hint?.desc : nil) ?? scope.source.descending(scope.reverse)
        let sort = mark?.sort ?? (useServer ? hint?.sort : nil) ?? scope.sortField
        openCursor = CreatorPlaybackCursor(
          scope, type: type, desc: desc, sort: sort,
          reportable: scope.source.uploads || mark?.reportable == true
            || (useServer && hint?.sort != nil))
      }
      if let c = openCursor {
        let center = CreatorPlaybackCursor.centre
        do {
          let slice = try await c.get(center, anchor: oid, initial: true)
          guard epoch == token, !Task.isCancelled else { throw CancellationError() }
          if let oid,
            !(kind.isShared
              ? slice.entries.contains(where: {
                $0.sharedSelectable && $0.genuineBV.flatMap(ArchiveNumber.av) == oid
              }) : slice.videos.contains(where: { ArchiveNumber.av($0.bvid) == oid }))
          {
            throw ServiceError("原视频已不在这个列表中")
          }
          cursor = c
          put(slice)
          if let oid,
            let slot = window.slots(center).first(where: { ArchiveNumber.av($0.item.id) == oid })
          {
            set(slot)
            return
          }
          if try await move(nil, forward: true, token: token, starting: center) { return }
          issue = "列表里没有可播放的视频"
          return
        } catch {
          guard epoch == token, !Task.isCancelled else { throw CancellationError() }
          // Service denials and a deleted anchor stay visible. Do not substitute an unrelated
          // first item or attempt the same request with a different account or API.
          throw error
        }
      }
      if let target, let match = try await search(target, start: page, token: token) {
        set(match)
        return
      }
      if target != nil {
        issue = "原条目已不在播放列表中"
        if case .creator = kind { return }
      }
      window.reversed = start.descending
      let initial = start.descending ? max(1, start.page) : 1
      if !(try await move(nil, forward: true, token: token, starting: initial)) && issue == nil {
        issue = "列表里没有可播放的视频"
      }
    } catch { if token == epoch && !Task.isCancelled { issue = error.localizedDescription } }
  }
  private func set(_ slot: Window.Slot, fullscreen: Bool = false) {
    let before = current?.item.id
    resumeFullscreen = fullscreen
    current = slot
    if let before, before != slot.item.id { report(slot) }
    remember()
  }
  private func report(_ s: Window.Slot) {
    guard case .creator(let scope, _) = kind, let aid = ArchiveNumber.av(s.item.id) else { return }
    let desc = (cursor?.descending ?? scope.source.descending(scope.reverse)) != window.reversed
    reporter.changed(
      scope.history(
        aid: aid, descending: desc, canReport: cursor?.reportable ?? scope.source.uploads),
      owners: scope.owners)
  }
  func select(_ s: Window.Slot, fullscreen: Bool = false) {
    guard s.item.queueTarget != nil, !busy else { return }
    issue = nil
    set(s, fullscreen: fullscreen)
  }
  var showsReversed: Bool {
    if let cursor {
      return (cursor.descending != cursor.scope.defaultDescending)
        != window.reversed
    }
    return window.reversed
  }
  func point(_ s: Window.Slot) -> ArchiveStart? {
    s.item.libraryPoint ?? cursor?.cid(s.item.id).map { ArchiveStart(cid: $0) }
  }
  private func restartCursor(
    _ c: CreatorPlaybackCursor, descending: Bool, fullscreen: Bool, token: UUID,
    reportDirection: Bool = false
  ) async throws {
    let next = CreatorPlaybackCursor(
      c.scope, type: c.type, desc: descending, sort: c.sort,
      reportable: c.reportable)
    var n = CreatorPlaybackCursor.centre
    var parts = [CreatorPlaybackCursor.Slice]()
    while true {
      let p = try await next.get(n, initial: parts.isEmpty)
      parts.append(p)
      guard token == epoch, !Task.isCancelled else { throw CancellationError() }
      if kind.isShared ? p.entries.contains(where: \.sharedPlayable) : !p.videos.isEmpty { break }
      if !p.later { throw ServiceError("列表里没有可播放的视频") }
      n += 1
    }
    cursor = next
    window = Window(identify: { $0.id }, playable: { $0.advancesInQueue })
    for p in parts { put(p) }
    if let first = window.slots(n).first(where: { $0.item.advancesInQueue }) {
      let same = current?.item.id == first.item.id
      set(first, fullscreen: fullscreen)
      if same && reportDirection { report(first) }
    }
  }
  func reverse(fullscreen: Bool = false) async {
    guard !busy else { return }
    busy = true
    issue = nil
    let token = epoch
    defer { if token == epoch { busy = false } }
    do {
      if let c = cursor {
        try await restartCursor(
          c, descending: !(c.descending != window.reversed), fullscreen: fullscreen, token: token,
          reportDirection: true)
      } else {
        let reversed = !window.reversed
        if reversed && window.end == nil {
          var n = 1
          if case .favorites(let folder) = kind, term.isEmpty, let count = folder.media_count {
            n = max(1, (count + 19) / 20)
          }
          while window.end == nil {
            try await load(n, token)
            n += 1
          }
        }
        guard token == epoch, !Task.isCancelled else { throw CancellationError() }
        let old = window.reversed
        window.reversed = reversed
        do {
          if try await move(
            nil, forward: true, token: token, fullscreen: fullscreen,
            starting: reversed ? window.end ?? 1 : window.beginning)
          {
            remember()
          } else {
            window.reversed = old
            issue = "列表里没有可播放的视频"
          }
        } catch {
          window.reversed = old
          throw error
        }
      }
    } catch { if token == epoch && !Task.isCancelled { issue = error.localizedDescription } }
  }
  func advance(_ forward: Bool, fullscreen: Bool = false) async -> Bool {
    guard !busy else { return false }
    let token = epoch
    busy = true
    issue = nil
    defer { if token == epoch { busy = false } }
    do {
      return try await move(current, forward: forward, token: token, fullscreen: fullscreen)
    } catch {
      if token == epoch && !Task.isCancelled { issue = error.localizedDescription }
      return false
    }
  }
  func ended(_ fullscreen: Bool, _ mode: VideoRepeat) async -> NextPlayback {
    guard !busy, let id = current?.item.id else { return .failed }
    let token = epoch
    busy = true
    issue = nil
    defer { if token == epoch { busy = false } }
    do {
      if try await move(current, forward: true, token: token, fullscreen: fullscreen) {
        return .advanced
      }
      guard mode == .cycle else { return .end }
      var start = window.beginning
      if let c = cursor {
        try await restartCursor(
          c, descending: c.descending != window.reversed, fullscreen: fullscreen, token: token)
        return current?.item.id == id ? .restart : .advanced
      } else if window.reversed {
        while window.end == nil {
          try await load(start, token)
          start += 1
        }
        start = window.end ?? 1
      }
      guard
        try await move(nil, forward: true, token: token, fullscreen: fullscreen, starting: start)
      else { return .end }
      return current?.item.id == id ? .restart : .advanced
    } catch {
      if token == epoch && !Task.isCancelled { issue = error.localizedDescription }
      return .failed
    }
  }
  private func move(
    _ row: Window.Slot?, forward: Bool, token: UUID, fullscreen: Bool = false, starting: Int = 1
  )
    async throws -> Bool
  {
    while true {
      try Task.checkCancellation()
      guard token == epoch else { throw CancellationError() }
      switch window.step(from: row, forward: forward, starting: starting) {
      case .found(let s):
        set(s, fullscreen: fullscreen)
        return true
      case .fetch(let n): try await load(n, token)
      case .finished: return false
      }
    }
  }
  func missingPage(_ later: Bool) -> Int? {
    let delta = later != window.reversed ? 1 : -1
    var n = (current?.number ?? 1) + delta
    while n >= window.beginning && (window.end.map { n <= $0 } ?? true) {
      if !window.has(n) { return n }
      n += delta
    }
    return nil
  }
  func more(_ later: Bool) async {
    guard !busy, let n = missingPage(later) else { return }
    busy = true
    let token = epoch
    defer { if token == epoch { busy = false } }
    do { try await load(n, token) } catch {
      if !Task.isCancelled && token == epoch { issue = error.localizedDescription }
    }
  }
  func invalidate() {
    epoch = UUID()
    reporter.stop()
    busy = false
  }
  func remove(_ slot: Window.Slot, fullscreen: Bool = false) async {
    guard allowChanges else { return }
    guard !busy, let resource = kind.resource(slot.item) else { return }
    let old: Window.Slot? = {
      guard let current, current.item.id == slot.item.id else { return current }
      for dir in [true, false] {
        if case .found(let neighbor) = window.step(from: current, forward: dir) { return neighbor }
      }
      return nil
    }()
    let wasReversed = window.reversed
    busy = true
    issue = nil
    let token = epoch
    defer { if token == epoch { busy = false } }
    do {
      try await kind.remove(resource, uid: uid)
      guard token == epoch, !Task.isCancelled else { return }
      window = Window(identify: { $0.id }, playable: { $0.advancesInQueue })
      window.reversed = wasReversed
      if let old,
        let hit = try await search(old.item.id, start: old.number, token: token)
      {
        set(hit, fullscreen: fullscreen)
        return
      }
      current = nil
      try await load(slot.number, token)
      let start = max(1, min(slot.number, window.end ?? slot.number))
      var direction = wasReversed ? -1 : 1
      for _ in 0..<2 {
        var p = start
        while p > 0 && (window.end.map { p <= $0 } ?? true) {
          try await load(p, token)
          if let hit = window.slots(p).first(where: { $0.item.queueTarget != nil }) {
            set(hit, fullscreen: fullscreen)
            return
          }
          p += direction
        }
        direction = -direction
      }
      issue = "列表里没有可播放的视频"
    } catch { if token == epoch && !Task.isCancelled { issue = error.localizedDescription } }
  }
}
