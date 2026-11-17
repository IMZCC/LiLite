import Foundation

#if canImport(CryptoKit)
  import CryptoKit
  import CommonCrypto
#else
  import Crypto
  @_silgen_name("PKCS5_PBKDF2_HMAC") private func linuxPBKDF2(
    _ p: UnsafePointer<CChar>, _ n: Int32, _ s: UnsafePointer<UInt8>, _ m: Int32,
    _ iterations: Int32, _ alg: OpaquePointer, _ length: Int32, _ out: UnsafeMutablePointer<UInt8>
  ) -> Int32
  @_silgen_name("EVP_sha256") private func linuxSHA256() -> OpaquePointer
#endif

/// Version byte fixes the KDF, work factor and AEAD. Header and salt are authenticated.
enum DataPackCipher {
  static let magic = Data([80, 73, 76, 73, 80, 65, 67, 75])
  static let overhead = 8 + 1 + 16 + 12 + 16
  static let bodyLimit = 64 * 1024 * 1024
  static func sealed(_ data: Data) -> Bool { data.starts(with: magic) }
  private static func key(_ password: String, _ salt: Data) throws -> SymmetricKey {
    let pass = Array(password.precomposedStringWithCanonicalMapping.utf8CString)
    guard pass.count > 1, pass.count <= 1025, salt.count == 16 else { throw ServiceError("备份密码无效") }
    var out = [UInt8](repeating: 0, count: 32)
    defer { _ = out.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
    let result = salt.withUnsafeBytes { bytes -> Bool in
      let s = bytes.bindMemory(to: UInt8.self).baseAddress!
      #if canImport(CryptoKit)
        return CCKeyDerivationPBKDF(
          CCPBKDFAlgorithm(kCCPBKDF2), pass, pass.count - 1, s, 16,
          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000, &out, 32) == kCCSuccess
      #else
        return linuxPBKDF2(pass, Int32(pass.count - 1), s, 16, 600_000, linuxSHA256(), 32, &out)
          == 1
      #endif
    }
    guard result else { throw ServiceError("无法处理备份密码") }
    return SymmetricKey(data: out)
  }
  static func encrypt(_ data: Data, password: String) throws -> Data {
    guard !data.isEmpty, data.count <= bodyLimit, password.count >= 10 else {
      throw ServiceError("备份密码至少需要 10 个字符，数据包不能超过 64 MB")
    }
    var rng = SystemRandomNumberGenerator()
    let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
    let header = magic + Data([1]) + salt
    let box = try AES.GCM.seal(data, using: key(password, salt), authenticating: header)
    guard let combined = box.combined else { throw ServiceError("无法加密数据包") }
    return header + combined
  }
  static func decrypt(_ data: Data, password: String) throws -> Data {
    guard sealed(data), data.count > overhead, data.count <= bodyLimit + overhead, data[8] == 1
    else { throw ServiceError("不支持的加密数据包") }
    let header = Data(data.prefix(25))
    do {
      let box = try AES.GCM.SealedBox(combined: Data(data.dropFirst(25)))
      return try AES.GCM.open(
        box, using: key(password, Data(header.suffix(16))), authenticating: header)
    } catch { throw ServiceError("密码不正确或数据包已损坏") }
  }
}
