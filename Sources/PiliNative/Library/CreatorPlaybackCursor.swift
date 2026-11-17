import Foundation

/// The service anchors around an archive, not around an absolute page number. A logical centre
/// page leaves space on both sides; a real empty/end response tightens the corresponding edge.
@MainActor final class CreatorPlaybackCursor {
  static let centre = 5_000_001
  struct Slice {
    let number: Int, videos: [Video], entries: [CreatorCursorMedia], first: Int64?, last: Int64?,
      firstType: Int, lastType: Int, prior: Bool, later: Bool
  }
  let scope: MediaCursorScope, type: Int, descending: Bool, sort: Int, reportable: Bool
  typealias Fetch = @MainActor ([String: String], String) async throws -> CreatorCursorReply
  private var pages: [Int: Slice] = [:], cids: [String: Int64] = [:]
  private(set) var total: Int?
  private let fetch: Fetch
  func cid(_ bvid: String) -> Int64? { cids[bvid] }
  convenience init(_ scope: CreatorArchiveScope, type: Int, desc: Bool, sort: Int, reportable: Bool)
  {
    self.init(.creator(scope), type: type, desc: desc, sort: sort, reportable: reportable)
  }
  init(
    _ scope: MediaCursorScope, type: Int, desc: Bool, sort: Int, reportable: Bool,
    fetch: @escaping Fetch = { fields, owner in
      try await BiliAPI.shared.read(
        "/x/v2/medialist/resource/list", fields, expectedAccount: owner, as: CreatorCursorReply.self
      )
    }
  ) {
    self.fetch = fetch
    self.scope = scope
    self.type = type
    descending = desc
    self.sort = sort
    self.reportable = reportable
  }
  // Normal browsing walks the published cursor. For a distant explicit page jump use the
  // catalogue's own page-number API to identify its first archive; never crawl an entire space.
  func browsing(_ n: Int) async throws -> Slice {
    guard n > 0, n <= 10_000_000 else { throw ServiceError("无效页码") }
    if let v = pages[n] { return v }
    if pages.isEmpty && n == 1 { return try await get(1, initial: true) }
    let nearby = pages.keys.min { abs($0 - n) < abs($1 - n) } ?? 1
    if abs(n - nearby) > 3 {
      guard case .creator(let catalog) = scope else { throw ServiceError("请按列表顺序翻页") }
      let p = try await CreatorArchiveCatalog.page(catalog, n, size: 20)
      guard let oid = p.videos.first.flatMap({ ArchiveNumber.av($0.bvid) }) else {
        throw ServiceError("这一页没有投稿")
      }
      return try await get(n, anchor: oid, initial: true)
    }
    if pages.isEmpty { _ = try await get(1, initial: true) }
    var at = nearby
    while at != n {
      try Task.checkCancellation()
      let step = n > at ? 1 : -1
      if let current = pages[at], !(step > 0 ? current.later : current.prior) {
        throw ServiceError("页码不在范围内")
      }
      at += step
      _ = try await get(at)
    }
    guard let result = pages[n] else { throw ServiceError("无法定位这一页") }
    return result
  }
  func get(_ number: Int, anchor opening: Int64? = nil, initial: Bool = false) async throws -> Slice
  {
    if let p = pages[number] { return p }
    var prior = false
    var oid = opening
    var edgeType = 2
    if !initial {
      if let prev = pages[number - 1], prev.later {
        oid = prev.last
        edgeType = prev.lastType
      } else if let after = pages[number + 1], after.prior {
        oid = after.first
        edgeType = after.firstType
        prior = true
      } else {
        throw ServiceError("列表位置已更新，请重新打开")
      }
      guard oid != nil else { throw ServiceError("播放列表未返回游标") }
    }
    let f = MediaCursorScope.request(
      business: scope.business, type: type, desc: descending, sort: sort, anchor: oid,
      edgeType: edgeType, prior: prior,
      include: initial && oid != nil)
    let response = try await fetch(f, scope.owner)
    try Task.checkCancellation()
    if let count = response.total_count, count >= 0, count <= 200_000_000 { total = count }
    let raw = response.media_list ?? []
    var seen = Set<String>()
    let entries = raw.filter { r in
      guard let id = r.key, id > 0, initial || id != oid || r.rowType != edgeType,
        seen.insert("\(r.rowType):\(id)").inserted
      else {
        return false
      }
      return true
    }
    let hasMore = response.has_more == true && !entries.isEmpty
    let previous =
      initial
      ? opening != nil && (entries.first?.index.map { $0 > 0 } ?? true) : prior ? hasMore : true
    let next = initial || !prior ? hasMore : true
    let result = Slice(
      number: number, videos: entries.compactMap(\.video), entries: entries,
      first: entries.first?.key,
      last: entries.last?.key, firstType: entries.first?.rowType ?? 2,
      lastType: entries.last?.rowType ?? 2, prior: previous, later: next)
    if !initial, !entries.isEmpty, let oid,
      ((prior ? result.first : result.last) == oid
        && (prior ? result.firstType : result.lastType) == edgeType)
        || pages.values.contains(where: {
          $0.first == result.first && $0.last == result.last && $0.firstType == result.firstType
            && $0.lastType == result.lastType
        })
    {
      throw ServiceError("服务没有返回新的播放条目")
    }
    for e in entries {
      if let id = e.rowID, let c = e.pages?.compactMap({ $0.id?.number }).first(where: { $0 > 0 }) {
        cids[id] = c
      }
    }
    pages[number] = result
    return result
  }
}
@MainActor final class CreatorHistoryReporter {
  typealias Send = @MainActor ([String: String], CreatorQueueOwners) async throws -> Void
  private var pending: ([String: String], CreatorQueueOwners)?, work: Task<Void, Never>?,
    sent: [String: String]?, ticket = UUID()
  let send: Send
  init(
    send: @escaping Send = { fields, owners in
      let state = try await AccountJar.shared.presentedState()
      let fresh = CreatorQueueOwners(state)
      guard fresh == owners, !owners.history.isEmpty else { throw ServiceError("账号已切换") }
      try await BiliAPI.shared.submit(
        "/x/v1/medialist/history", fields, expectedAccount: owners.history)
    }
  ) { self.send = send }
  func changed(_ fields: [String: String]?, owners: CreatorQueueOwners) {
    guard let fields, !owners.history.isEmpty else { return }
    pending = (fields, owners)
    guard work == nil else { return }
    let event = ticket
    work = Task { [weak self] in
      guard let self else { return }
      defer { if event == ticket { work = nil } }
      while !Task.isCancelled, event == ticket, let (next, owners) = pending {
        pending = nil
        guard sent != next else { continue }
        do {
          try await send(next, owners)
          if !Task.isCancelled, event == ticket { sent = next }
        } catch {}
      }
    }
  }
  func settled() async { await work?.value }
  func stop() {
    ticket = UUID()
    pending = nil
    work?.cancel()
    work = nil
    sent = nil
  }
}
