// In-process stand-ins for the server and Apple UI; the queue, cursor, account routing table,
// archive catalogue, report serializer and page window under test are production sources.
import Foundation

protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<V> { var wrappedValue: V }
struct ServiceError: LocalizedError {
  let message: String
  init(_ m: String) { message = m }
  var errorDescription: String? { message }
}
struct Video {
  let bvid: String, title: String
  var historyKey: String? { nil }
  static func preview(
    id: String, title: String, cover: String, author: String?, duration: Int? = nil
  ) -> Self { .init(bvid: id, title: title) }
}
struct Folder { let id: Int64, title: String, media_count: Int? }
enum FavoriteSort: String { case mtime, view, pubtime }
struct FavoriteMedia { let id: String, valid: Bool }
struct LaterMedia {
  let id: String, valid: Bool
  var resource: Int64? { Int64(id) }
}
struct Page<T> {
  let items: [T], next: String?
  func transform<U>(_ f: (T) -> U) -> Page<U> { .init(items: items.map(f), next: next) }
}
struct ArchiveStart {
  let cid: Int64
  var seconds: Double? = nil
}
enum CloudEntry {
  case sharedItem(CreatorCursorMedia)
  case video(Video)
  case favorite(FavoriteMedia)
  case later(LaterMedia)
  var id: String {
    switch self {
    case .sharedItem(let v): v.displayID
    case .video(let v): v.bvid
    case .later(let v): v.id
    case .favorite(let f): f.id
    }
  }
  var queueTarget: Bool? {
    switch self {
    case .sharedItem(let v): v.sharedSelectable ? true : nil
    case .video: true
    case .later(let l): l.valid ? true : nil
    case .favorite(let f): f.valid ? true : nil
    }
  }
  var libraryPoint: ArchiveStart? { nil }
}
enum LibraryPlaylistSignature { static func key(_ s: String) -> String { s } }
enum PlaybackMemory { @MainActor static var enabled = true }
actor AccountJar {
  struct State {
    let owners: CreatorQueueOwners
    func owner(_ use: AccountUse) -> String? {
      switch use {
      case .role(.main): owners.main
      case .role(.video): owners.video
      case .role(.recommend): owners.recommend
      default: owners.history
      }
    }
  }
  static let shared = AccountJar()
  var owners = CreatorQueueOwners(main: "A", recommend: "R", history: "H", video: "V")
  func set(_ o: CreatorQueueOwners) { owners = o }
  func presentedState() throws -> State { .init(owners: owners) }
}
actor BiliAPI {
  static let shared = BiliAPI()
  struct Call { let path: String, fields: [String: String], owner: String }
  struct Edition { let list: [Video]? }
  var reads = [Call](), posts = [Call](), deny = false, deleted = Set<String>()
  func reset() {
    reads = []
    posts = []
    deny = false
    deleted = []
  }
  func reject(_ v: Bool) { deny = v }
  private func page(_ a: [Int64], _ pn: Int) -> [Int64] {
    Array(a.dropFirst(min(a.count, max(0, (pn - 1) * 3))).prefix(3))
  }
  func sign(_ f: [String: String]) async throws -> [String: String] { f }
  func read<T: Decodable>(
    _ path: String, _ f: [String: String], host: String = "api.bilibili.com",
    expectedAccount: String? = nil, as: T.Type
  ) async throws -> T {
    let actor = try await AccountJar.shared.presentedState()
    guard expectedAccount == actor.owner(AccountRoutes.service(path, host: host)) else {
      throw ServiceError("actor mismatch")
    }
    reads.append(.init(path: path, fields: f, owner: expectedAccount ?? ""))
    guard !deny else { throw ServiceError("拒绝访问") }
    let out: [String: Any]
    if path == "/x/v2/medialist/resource/list" {
      var arr = (101...112).map(Int64.init)
      if f["sort_field"] == "2" {
        arr = [106, 105, 104, 103, 102, 101, 112, 111, 110, 109, 108, 107]
      }
      if f["desc"] == "false" { arr.reverse() }
      let prior = f["direction"] == "true"
      let include = f["with_current"] == "true"
      let oid = f["oid"].flatMap(Int64.init)
      let i = oid.flatMap { arr.firstIndex(of: $0) }
      let ids: ArraySlice<Int64>
      if oid != nil, i == nil {
        ids = arr[0..<0]
      } else if prior {
        let b = i ?? 0
        ids = arr[max(0, b - 3)..<b]
      } else {
        let a = i.map { $0 + (include ? 0 : 1) } ?? 0
        ids = arr[a..<min(arr.count, a + 3)]
      }
      let shared = f["type"] == "3" && f["biz_id"] == "83"
      let rows: [[String: Any]] = ids.map { k in
        if shared && k == 109 {
          return [
            "id": k, "type": 24, "ep_id": 701, "index": arr.firstIndex(of: k)!, "title": "共享番剧",
            "pages": [["id": "9001"]],
          ]
        }
        return [
          "id": "\(k)", "type": 2, "index": arr.firstIndex(of: k)!, "title": "V\(k)",
          "pages": k == 110 ? [] : [["id": "\(k*10)"]],
        ]
      }
      out = [
        "media_list": rows,
        "has_more": ids.last.map { prior ? ids.first != arr.first : $0 != arr.last } ?? false,
        "total_count": arr.count,
      ]
    } else if path.contains("/x/v2/space/") {
      out = [
        "episodic_button": [
          "text": "继续播放", "uri": "bilibili://playlist/list?oid=107&page_type=8&desc=1&sort_field=2",
        ]
      ]
    } else {
      let pn = Int(f["pn"] ?? f["page_num"] ?? "1")!
      let start = (pn - 1) * 30
      let rows = (0..<min(30, max(0, 34 - start))).map { n in
        ["aid": Int64(901 + start + n), "title": "Filtered", "pic": "", "length": "0:40"]
          as [String: Any]
      }
      out = [
        "list": ["vlist": rows, "tlist": ["7": ["tid": 7, "name": "分区"]]], "archives": rows,
        "page": ["count": 34],
      ]
    }
    return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: out))
  }
  func submit(_ path: String, _ fields: [String: String], expectedAccount: String?) async throws {
    let a = try await AccountJar.shared.presentedState()
    guard expectedAccount == a.owner(AccountRoutes.service(path, host: "api.bilibili.com")), !deny
    else { throw ServiceError("拒绝回执") }
    posts.append(.init(path: path, fields: fields, owner: expectedAccount ?? ""))
    if let id = fields["resources"] { deleted.insert(id) }
  }
  func favoriteMedia(_ id: Int64, page pn: Int, term: String, order: FavoriteSort, user: String)
    async throws -> Page<FavoriteMedia>
  {
    reads.append(
      .init(
        path: "favorite", fields: ["query": term, "order": order.rawValue, "pn": String(pn)],
        owner: user))
    let ids = (1...8).map(Int64.init).filter { !deleted.contains(String($0)) }
    return .init(
      items: page(ids, pn).map { .init(id: String($0), valid: $0 != 1) },
      next: pn * 3 < ids.count ? String(pn + 1) : nil)
  }
  func later(page pn: Int, keyword: String, viewed: Int, ascending: Bool, uid: String) async throws
    -> Page<LaterMedia>
  {
    reads.append(
      .init(
        path: "later",
        fields: [
          "query": keyword, "viewed": String(viewed), "ascending": String(ascending),
          "pn": String(pn),
        ], owner: uid))
    let ids = (viewed == 2 ? [2, 4, 6, 8] : [1, 2, 3, 4, 5, 6, 7, 8]).map(Int64.init).filter {
      !deleted.contains(String($0))
    }
    let a = ascending ? Array(ids.reversed()) : ids
    return .init(
      items: page(a, pn).map { .init(id: String($0), valid: $0 != 1) },
      next: pn * 3 < a.count ? String(pn + 1) : nil)
  }
  func history(cursor: String?, term: String, uid: String) async throws -> Page<Video> {
    .init(items: [], next: nil)
  }
  func curatedEdition(_ n: Int?, page: Int, owner: String) async throws -> Edition {
    .init(list: nil)
  }
}
