import Foundation
import Security

struct PackServerProfile {
  let address: String, user: String, directory: String, password: String
  static let pendingKey = "backup.dav.pendingProfile"
  static func read(_ box: [String: Any]) throws -> Self {
    guard let address = box["webdavUri"] as? String else { throw ServiceError("没有服务器配置") }
    func string(_ k: String, _ fallback: String) throws -> String {
      guard let v = box[k] else { return fallback }
      guard let x = v as? String, x.utf8.count <= 8192,
        x.rangeOfCharacter(from: .controlCharacters) == nil
      else { throw ServiceError("服务器配置格式无效") }
      return x
    }
    let u = try string("webdavUsername", "")
    let d = try string("webdavDirectory", "/")
    let pw = try string("webdavPassword", "")
    guard address.utf8.count <= 4096, !u.contains(":") else { throw ServiceError("服务器地址或用户名无效") }
    let target = try DAVLocation(address: address, directory: d, tablet: false)
    return Self(address: target.base.absoluteString, user: u, directory: d, password: pw)
  }
  static func current() throws -> Self {
    let d = UserDefaults.standard
    let value = try read([
      "webdavUri": d.string(forKey: "backup.dav.url") ?? "",
      "webdavUsername": d.string(forKey: "backup.dav.user") ?? "",
      "webdavDirectory": d.string(forKey: "backup.dav.directory") ?? "/",
    ])
    let location = try DAVLocation(
      address: value.address, directory: value.directory, tablet: false)
    return Self(
      address: value.address, user: value.user, directory: value.directory,
      password: try DAVSecrets.readPassword(location, user: value.user))
  }
  var upstream: [String: Any] {
    [
      "webdavUri": address, "webdavUsername": user, "webdavDirectory": directory,
      "webdavPassword": password,
    ]
  }

  // An imported endpoint can never replace an already trusted server or its saved credential.
  // The settings screen lets its user inspect a pending profile before explicitly connecting.
  struct Pending: Codable {
    let id: UUID, address: String, user: String, directory: String
  }
  private static func query(_ id: UUID) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "PiliNative.PendingDAV", kSecAttrAccount as String: id.uuidString,
    ]
  }
  func stage() throws -> (Pending, Data) {
    let entry = Pending(id: UUID(), address: address, user: user, directory: directory)
    let data = try JSONEncoder().encode(entry)
    var q = Self.query(entry.id)
    q[kSecValueData as String] = Data(password.utf8)
    q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else {
      throw ServiceError("未能暂存服务器配置")
    }
    return (entry, data)
  }
  static func discard(_ entry: Pending) throws {
    let code = SecItemDelete(query(entry.id) as CFDictionary)
    guard [errSecSuccess, errSecItemNotFound].contains(code) else {
      throw ServiceError("未能清除待验证的服务器配置")
    }
  }
  static func pendingPassword(_ entry: Pending) throws -> String {
    var q = query(entry.id)
    q[kSecReturnData as String] = true
    var item: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let bytes = item as? Data,
      let value = String(data: bytes, encoding: .utf8)
    else { throw ServiceError("无法读取待验证的服务器密码") }
    return value
  }
}
