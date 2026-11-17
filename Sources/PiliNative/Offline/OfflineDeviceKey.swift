import CryptoKit
import Foundation
import Security

extension OfflineSealedTrack {
  private static let fields: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "PiliNative.OfflineCache", kSecAttrAccount as String: "files-v1",
    kSecAttrSynchronizable as String: false,
  ]
  static func deviceKey(create: Bool) throws -> SymmetricKey {
    var q = fields
    q[kSecReturnData as String] = true
    var item: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &item)
    if status == errSecSuccess, let data = item as? Data, data.count == 32 {
      return .init(data: data)
    }
    guard create, status == errSecItemNotFound else { throw ServiceError("此设备无法读取缓存密钥") }
    let key = SymmetricKey(size: .bits256)
    var adding = fields
    adding[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
    adding[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let added = SecItemAdd(adding as CFDictionary, nil)
    if added == errSecDuplicateItem { return try deviceKey(create: false) }
    guard added == errSecSuccess else { throw ServiceError("无法保护账号缓存") }
    return key
  }
  static func context(_ v: OfflineVideo, _ part: String) -> Data {
    Data(("PiliNative Offline 1|" + (v.cacheOwner ?? "") + "|" + v.token + "|" + part).utf8)
  }
}
