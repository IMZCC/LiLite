import Foundation
import PiliWire
import SwiftUI

struct ListenOrigin: Codable, Equatable {
  let source: Int, id: Int64, extra: Int64?
  var initialPage: Int? = nil
  static func archive(_ id: Int64) -> Self { .init(source: 5, id: id, extra: nil) }
  static func card(_ id: Int64) -> Self { .init(source: 3, id: id, extra: nil) }
  static func member(_ id: Int64, page: Int = 1) -> Self {
    .init(source: 1, id: id, extra: nil, initialPage: max(1, page))
  }
  static func favorites(_ id: Int64) -> Self { .init(source: 4, id: id, extra: 2) }
  static func media(_ id: Int64, kind: Int64) -> Self { .init(source: 8, id: id, extra: kind) }
}
private struct ListenOriginKey: EnvironmentKey { static let defaultValue: ListenOrigin? = nil }
extension EnvironmentValues {
  var listenOrigin: ListenOrigin? {
    get { self[ListenOriginKey.self] }
    set { self[ListenOriginKey.self] = newValue }
  }
}
extension BiliAPI {
  nonisolated func listener(for uid: String?) -> ListenerGateway {
    ListenerGateway { m, d in
      try await self.mobileCall(m.path, d, uid: uid, needsToken: !m.reads, readOnly: m.reads)
    }
  }
}
extension ListenTrack {
  var objectID: Int64? { songID ?? episodeSource?.aid ?? ArchiveNumber.av(bvid) }
  var locator: ListenerGateway.Track? {
    guard let oid = objectID, oid > 0, cid > 0 else { return nil }
    return ListenerGateway.item(oid: oid, sub: cid, type: songID == nil ? 1 : 3)
  }
  var defaultOrigin: ListenOrigin? {
    if let origin { return origin }
    if let songID { return .card(songID) }
    return objectID.map(ListenOrigin.archive)
  }
  init?(_ item: ListenerGateway.Row, context: ListenOrigin, selected: Int64? = nil) {
    let oid = item.item.oid
    guard oid > 0, [1, 3].contains(item.item.itemType) else { return nil }
    let cid =
      selected ?? item.item.subID.first ?? item.parts.first?.subID
      ?? (item.item.itemType == 3 ? oid : 0)
    guard cid > 0 else { return nil }
    let archive = item.arc
    if item.item.itemType == 3 {
      self.init(
        AudioSong(
          id: oid, title: archive.title, author: item.owner.name, cover: archive.cover,
          intro: archive.desc, lyric: nil, duration: Int(archive.duration), bvid: nil),
        origin: context)
    } else {
      guard let bv = ArchiveNumber.bv(oid) else { return nil }
      let parts = item.parts.map {
        Video.Part(cid: $0.subID, duration: Int($0.duration), page: Int($0.page), part: $0.title)
      }
      self.init(
        Video(
          aid: oid, bvid: bv, title: archive.title, pic: archive.cover,
          owner: .init(mid: item.owner.mid, name: item.owner.name), stat: nil,
          duration: Int(archive.duration), desc: archive.desc, cid: cid, pages: parts), cid: cid,
        origin: context)
    }
    self.cid = cid
    self.ownerID = item.owner.mid
  }
}
@MainActor final class ListenerCatalog: ObservableObject {
  @Published private(set) var tracks: [ListenTrack] = []
  @Published private(set) var before: String?
  @Published private(set) var after: String?
  @Published private(set) var order = 1
  @Published private(set) var issue: String?
  @Published private(set) var busy = false
  @Published private(set) var usesListener = false
  @Published private(set) var origin: ListenOrigin?
  @Published private(set) var records: [String: ListenerGateway.Row] = [:]
  private var epoch = UUID(), seenBefore = Set<String>(), seenAfter = Set<String>()
  private var anchor: ListenTrack?
  private var owner: String?
  var hydrated: (() -> Void)?
  private var hidden = Set<String>()
  func reset() {
    epoch = UUID()
    tracks = []
    records = [:]
    before = nil
    after = nil
    order = 1
    issue = nil
    busy = false
    usesListener = false
    origin = nil
    anchor = nil
    owner = nil
    hidden = []
    seenBefore = []
    seenAfter = []
  }
  func open(_ t: ListenTrack, owner: String?) {
    reset()
    anchor = t
    origin = t.defaultOrigin
    self.owner = owner
    Task { await load(.first) }
  }
  enum Direction { case first, previous, next }
  func sort(_ new: Int, current: ListenTrack) {
    guard (0...3).contains(new), origin != nil else { return }
    order = new
    anchor = current
    epoch = UUID()
    busy = false
    seenAfter = []
    seenBefore = []
    Task { await load(.first) }
  }
  func omit(_ t: ListenTrack) {
    hidden.insert(t.bvid)
    tracks.removeAll { $0.bvid == t.bvid }
    records[t.bvid] = nil
  }
  func load(_ direction: Direction) async {
    guard !busy, let origin, let anchor, let item = anchor.locator else { return }
    let cursor = direction == .first ? nil : (direction == .next ? after : before)
    guard direction == .first || cursor != nil else { return }
    let token = epoch
    busy = true
    issue = nil
    defer { if epoch == token { busy = false } }
    do {
      let identity = try await AccountJar.shared.current(.role(.main),credentials:.mobile)
      try Task.checkCancellation()
      guard token == epoch, identity?.id == owner else { return }
      usesListener = identity?.mobileToken?.isEmpty == false
      if !usesListener {
        if origin.source == 1 {
          struct PublicRows: Decodable { let data: [AudioSong]?, totalSize: Int? }
          let n = cursor.flatMap(Int.init) ?? origin.initialPage ?? 1
          let result = try await BiliAPI.shared.read(
            "/audio/music-service/web/song/upper",
            [
              "uid": String(origin.id), "pn": String(n), "ps": "20", "order": "1",
              "web_location": "333.1387",
            ], expectedAccount: owner ?? "", as: PublicRows.self)
          try Task.checkCancellation()
          guard token == epoch else { return }
          let incoming = (result.data ?? []).map {
            ListenTrack($0, origin: .member(origin.id, page: n))
          }
          let merged =
            direction == .first
            ? incoming : direction == .previous ? incoming + tracks : tracks + incoming
          var seen = Set<String>()
          tracks = merged.filter { !hidden.contains($0.bvid) && seen.insert($0.bvid).inserted }
          if direction != .next { before = n > 1 ? String(n - 1) : nil }
          if direction != .previous {
            after =
              !incoming.isEmpty && (result.totalSize.map { n * 20 < $0 } ?? (incoming.count == 20))
              ? String(n + 1) : nil
          }
        } else {
          tracks = [anchor]
          before = nil
          after = nil
          if origin.source != 3 { issue = "来源队列需为主账号完成移动端授权" }
        }
        return
      }
      let page = try await BiliAPI.shared.listener(for: owner).playlist(
        id: origin.id, source: origin.source, extra: origin.extra, anchor: item, order: order,
        cursor: cursor)
      try Task.checkCancellation()
      guard token == epoch else { return }
      var catalog = direction == .first ? [:] : records
      let chunk = page.list.compactMap { row -> ListenTrack? in
        guard
          let t = ListenTrack(
            row, context: origin, selected: row.item.oid == anchor.objectID ? anchor.cid : nil),
          !hidden.contains(t.bvid)
        else { return nil }
        catalog[t.bvid] = row
        return t
      }
      var seen = Set<String>()
      let combined =
        direction == .first ? chunk : direction == .previous ? chunk + tracks : tracks + chunk
      tracks = combined.filter { seen.insert($0.bvid).inserted }
      records = catalog
      hydrated?()
      if direction != .previous {
        if let cursor { seenAfter.insert(cursor) }
        let c = page.paginationReply.next
        after = page.reachEnd || c.isEmpty || seenAfter.contains(c) ? nil : c
      }
      if direction != .next {
        if let cursor { seenBefore.insert(cursor) }
        let c = page.paginationReply.prev
        before = page.reachStart || c.isEmpty || seenBefore.contains(c) ? nil : c
      }
    } catch { if epoch == token && !Task.isCancelled { issue = error.localizedDescription } }
  }
  func update(_ action: ListenerGateway.Action, track: ListenTrack, owner: String) async throws
    -> String
  {
    guard self.owner == owner, let item = track.locator else { throw ServiceError("账号或音频已切换") }
    let token = epoch
    let ack = try await BiliAPI.shared.listener(for: owner).update(action, item: item)
    guard token == epoch else { throw CancellationError() }
    if var row = records[track.bvid] {
      switch action {
      case .like(let value):
        if row.stat.hasLike_p != value { row.stat.like = max(0, row.stat.like + (value ? 1 : -1)) }
        row.stat.hasLike_p = value
      case .coin(let count, _):
        if ack.coin {
          row.stat.coin += count
          row.stat.hasCoin_p = true
        }
        if ack.like && !row.stat.hasLike_p {
          row.stat.hasLike_p = true
          row.stat.like += 1
        }
      case .triple:
        if ack.coin && !row.stat.hasCoin_p {
          row.stat.hasCoin_p = true
          row.stat.coin += 2
        }
        if ack.like && !row.stat.hasLike_p {
          row.stat.hasLike_p = true
          row.stat.like += 1
        }
        if ack.fav && !row.stat.hasFav_p {
          row.stat.hasFav_p = true
          row.stat.favourite += 1
        }
      }
      records[track.bvid] = row
    }
    return ack.message.isEmpty ? "操作已提交" : ack.message
  }
}
