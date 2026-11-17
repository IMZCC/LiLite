import Combine
import Foundation

@MainActor final class AccountBulletRules: ObservableObject {
  static let shared = AccountBulletRules()
  @Published private(set) var revision = UUID()
  private var epochs = [String: UUID](), writing = Set<String>()
  private func key(_ owner: String) -> String { "dm.account.rules." + owner }
  func rows(_ owner: String?) -> [CloudBulletRule] {
    guard let owner, let data = UserDefaults.standard.data(forKey: key(owner)) else { return [] }
    return (try? JSONDecoder().decode([CloudBulletRule].self, from: data)) ?? []
  }
  func changedAccount() { revision = UUID() }
  func forget(_ owner: String) {
    UserDefaults.standard.removeObject(forKey: key(owner))
    epochs[owner] = UUID()
    revision = UUID()
  }
  private func save(_ rows: [CloudBulletRule], owner: String) throws {
    UserDefaults.standard.set(try JSONEncoder().encode(rows), forKey: key(owner))
    revision = UUID()
  }
  func sync(_ owner: String) async throws -> String? {
    guard !writing.contains(owner) else { return nil }
    let epoch = UUID()
    epochs[owner] = epoch
    struct Result: Decodable { let rule: [CloudBulletRule]?, toast: String? }
    let page = try await BiliAPI.shared.read("/x/dm/filter/user", [:], expectedAccount: owner, as: Result.self)
    guard epochs[owner] == epoch, !Task.isCancelled else { return nil }
    try save((page.rule ?? []).filter { $0.id > 0 && (0...2).contains($0.type) }, owner: owner)
    return page.toast
  }
  func update(_ owner: String, type: Int, input: String, senderHash: Bool = false, replacing old: CloudBulletRule? = nil) async throws {
    let value = try CloudBulletRule.input(input, type: type, senderHash: senderHash)
    if let old, old.type == type && (old.filter == value || old.display == value) { return }
    guard writing.insert(owner).inserted else { throw ServiceError("请稍后再试") }
    let epoch = UUID()
    epochs[owner] = epoch
    defer { writing.remove(owner) }
    struct Ack: Decodable { let data: CloudBulletRule }
    let bytes = try await BiliAPI.shared.submitResponse("/x/dm/filter/user/add", ["filter": value, "type": String(type)], expectedAccount: owner)
    let added = try JSONDecoder().decode(Ack.self, from: bytes).data
    guard added.id > 0, added.type == type else { throw ServiceError("请刷新屏蔽规则") }
    guard epochs[owner] == epoch else { return }
    var next = rows(owner).filter { $0.id != added.id }
    next.append(added)
    try save(next, owner: owner)
    if let old, old.id != added.id {
      do { try await erase(old, owner: owner, epoch: epoch) }
      catch { throw ServiceError("新规则已保存，旧规则未删除：" + error.localizedDescription) }
    }
  }
  func remove(_ row: CloudBulletRule, owner: String) async throws {
    guard writing.insert(owner).inserted else { throw ServiceError("请稍后再试") }
    defer { writing.remove(owner) }
    let epoch = UUID()
    epochs[owner] = epoch
    try await erase(row, owner: owner, epoch: epoch)
  }
  private func erase(_ row: CloudBulletRule, owner: String, epoch: UUID) async throws {
    guard row.id > 0 else { throw ServiceError("规则无效") }
    try await BiliAPI.shared.submit("/x/dm/filter/user/del", ["ids": String(row.id)], expectedAccount: owner)
    guard epochs[owner] == epoch else { return }
    try save(rows(owner).filter { $0.id != row.id }, owner: owner)
  }
}
