import Foundation
import Security

struct PackContributor {
  let base: URL, id: String
  static func checked(_ id: String) throws -> String {
    guard (16...256).contains(id.utf8.count),
      id.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || [45, 95].contains($0)
      })
    else { throw ServiceError("空降助手贡献 ID 无效") }
    return id
  }
  static func existing(_ base: URL) throws -> String? {
    var q = SponsorIdentity.key(base)
    q[kSecReturnData as String] = true
    var result: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let d = result as? Data,
      let id = String(data: d, encoding: .utf8)
    else { throw ServiceError("无法读取空降助手贡献身份") }
    return try checked(id)
  }
  static func current() throws -> Self {
    let base = try SponsorAPI().base
    guard let id = try existing(base) else { throw ServiceError("当前空降助手服务器没有已保存的贡献身份") }
    return .init(base: base, id: id)
  }
  static func read(_ box: [String: Any]) throws -> Self {
    guard let id = box["blockUserID"] as? String else { throw ServiceError("数据包没有空降助手贡献 ID") }
    let url = try SponsorAPI(box["blockServer"] as? String ?? "https://www.bsbsb.top").base
    return Self(base: url, id: try checked(id))
  }
  func install() throws -> Bool {
    if let old = try Self.existing(base) {
      guard old == id else { throw ServiceError("该服务器已有不同的贡献身份，请取消此项或在空降助手中手动更换") }
      return false
    }
    var q = SponsorIdentity.key(base)
    q[kSecValueData as String] = Data(id.utf8)
    q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else {
      throw ServiceError("无法导入空降助手贡献身份")
    }
    return true
  }
  func undo() throws {
    guard try Self.existing(base) == id else { throw ServiceError("贡献身份已变更，无法撤销") }
    guard SecItemDelete(SponsorIdentity.key(base) as CFDictionary) == errSecSuccess else {
      throw ServiceError("无法撤销贡献身份")
    }
  }
}
