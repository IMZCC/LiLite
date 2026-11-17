import Foundation

enum CloudLibraryKind {
  case shared(Int64, CreatorQueueOwners)
  case history, later
  case favorites(Folder)
  case curated(Int?)
  case creator(CreatorArchiveScope, CreatorQueueHint?)
  var readingRole: AccountUse {
    if case .curated = self { return .role(.recommend) }
    return .role(.main)
  }
  var cursorOwners: CreatorQueueOwners? {
    switch self {
    case .shared(_, let owners): owners
    case .creator(let s, _): s.owners
    default: nil
    }
  }
  var isShared: Bool {
    if case .shared = self { return true }
    return false
  }
  var storageID: String {
    if case .shared(let id, let owners) = self {
      return "playlist:" + String(id) + ":" + owners.key.map { "\($0.utf8.count):\($0)" }.joined()
    }
    if case .creator(let s, _) = self { return s.storageKey }
    if case .history = self { return "history" }
    if case .curated(let n) = self { return n.map { "week-" + String($0) } ?? "precious" }
    return folder.map(String.init) ?? "later"
  }
  var title: String {
    switch self {
    case .shared: return "播放列表"
    case .creator(let s, _): return s.title
    case .curated(let week): return week == nil ? "入站必刷" : "每周必看"
    case .history: return "观看历史"
    case .later: return "稍后再看"
    case .favorites(let f): return f.title
    }
  }
  var folder: Int64? {
    if case .favorites(let f) = self { return f.id }
    return nil
  }
  var canTransfer: Bool {
    if isShared { return false }
    if case .creator = self { return false }
    if case .curated = self { return false }
    if case .history = self { return false }
    return true
  }
  func fetch(
    _ cursor: String?, query: String, order: FavoriteSort, uid: String, viewed: Int = 0,
    ascending: Bool = false
  ) async throws
    -> Page<CloudEntry>
  {
    let p = Int(cursor ?? "1") ?? 1
    switch self {
    case .shared: throw ServiceError("请从列表中的视频打开")
    case .creator(let scope, _):
      let page = try await CreatorArchiveCatalog.page(scope, p)
      return Page(items: page.videos.map(CloudEntry.video), next: page.more ? String(p + 1) : nil)
    case .curated(let number):
      let edition = try await BiliAPI.shared.curatedEdition(number, page: p, owner: uid)
      let rows = edition.list ?? []
      return Page(
        items: rows.map(CloudEntry.video),
        next: number == nil && !rows.isEmpty ? String(p + 1) : nil)
    case .history:
      return try await BiliAPI.shared.history(cursor: cursor, term: query, uid: uid).transform(
        CloudEntry.video)
    case .later:
      return try await BiliAPI.shared.later(
        page: p, keyword: query, viewed: viewed, ascending: ascending, uid: uid
      ).transform(CloudEntry.later)
    case .favorites(let f):
      return try await BiliAPI.shared.favoriteMedia(
        f.id, page: p, term: query, order: order, user: uid
      ).transform(CloudEntry.favorite)
    }
  }
  func resource(_ v: CloudEntry) -> String? {
    switch (self, v) {
    case (.history, .video(let x)): return x.historyKey
    case (.later, .later(let x)): return x.resource.map(String.init)
    case (.favorites, .favorite(let x)): return x.id
    default: return nil
    }
  }
  func remove(_ ids: String, uid: String) async throws {
    let api = BiliAPI.shared
    switch self {
    case .shared: throw ServiceError("这个播放列表不可编辑")
    case .creator: throw ServiceError("这个投稿列表不可编辑")
    case .curated: throw ServiceError("这个榜单不可编辑")
    case .history:
      try await api.submit(
        "/x/v2/history/delete", ["kid": ids, "jsonp": "jsonp"], expectedAccount: uid)
    case .later:
      try await api.submit("/x/v2/history/toview/v2/dels", ["resources": ids], expectedAccount: uid)
    case .favorites(let f):
      try await api.submit(
        "/x/v3/fav/resource/batch-deal",
        ["resources": ids, "del_media_ids": "\(f.id)", "add_media_ids": ""], expectedAccount: uid)
    }
  }
  func transfer(_ ids: String, to target: Int64, copy: Bool, uid: String) async throws {
    guard canTransfer, folder != target else { throw ServiceError("请选择其他收藏夹") }
    var fields = ["tar_media_id": "\(target)", "resources": ids, "platform": "web"]
    if let folder { fields["src_media_id"] = "\(folder)" }
    if copy { fields["mid"] = uid }
    let prefix = folder == nil ? "/x/v2/history/toview/" : "/x/v3/fav/resource/"
    try await BiliAPI.shared.submit(prefix + (copy ? "copy" : "move"), fields, expectedAccount: uid)
  }
}
