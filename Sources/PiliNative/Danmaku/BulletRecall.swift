import Combine
import Foundation

@MainActor final class BulletRecall: ObservableObject {
  static let shared = BulletRecall()
  struct Key: Hashable { let cid: Int64, dmid: Int64 }
  private var authors = [Key: String](), order = [Key]()
  private var gone = Set<Key>(), removedOrder = [Key]()
  let changes = PassthroughSubject<Key, Never>()
  func posted(_ dmid: Int64?, cid: Int64, author: String) {
    guard let dmid, dmid > 0, cid > 0 else { return }
    let key = Key(cid: cid, dmid: dmid)
    if authors[key] == nil { order.append(key) }
    authors[key] = author
    if order.count > 1024 { authors[order.removeFirst()] = nil }
  }
  func owns(_ row: Bullet, cid: Int64, author: String) -> Bool {
    guard !author.isEmpty, let dmid = row.entryID, dmid > 0 else { return false }
    if let owner = authors[.init(cid: cid, dmid: dmid)] { return owner == author }
    // The CRC only determines the UI affordance. Authorization is always enforced by the service.
    return row.sender?.lowercased() == DanmakuStyle.senderHash(author)
  }
  func visible(_ row: Bullet, cid: Int64) -> Bool {
    row.entryID.map { !gone.contains(.init(cid: cid, dmid: $0)) } ?? true
  }
  func removedIDs(for cid: Int64) -> Set<Int64> {
    Set(gone.lazy.filter { $0.cid == cid }.map(\.dmid))
  }
  func recall(_ row: Bullet, cid: Int64, author: String) async throws {
    guard owns(row, cid: cid, author: author), let id = row.entryID else {
      throw ServiceError("只能撤回自己发送的弹幕")
    }
    try await BiliAPI.shared.submit(
      "/x/dm/recall", ["dmid": String(id), "cid": String(cid), "type": "1"], expectedAccount: author
    )
    let key = Key(cid: cid, dmid: id)
    guard !gone.contains(key) else { return }
    objectWillChange.send()
    gone.insert(key)
    removedOrder.append(key)
    if removedOrder.count > 2048 { gone.remove(removedOrder.removeFirst()) }
    authors[key] = nil
    order.removeAll { $0 == key }
    changes.send(key)
  }
}
