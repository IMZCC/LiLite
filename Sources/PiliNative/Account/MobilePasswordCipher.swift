import Foundation
import Security

enum MobilePasswordCipher {
  /// SecKey consumes PKCS#1, whereas the passport endpoint normally supplies SPKI PEM.
  static func publicKeyDER(_ pem: String) throws -> Data {
    guard pem.utf8.count <= 16_384,
      pem.contains("-----BEGIN PUBLIC KEY-----") || pem.contains("-----BEGIN RSA PUBLIC KEY-----")
    else { throw ServiceError("登录服务返回的加密密钥无效") }
    let encoded = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
    guard let der = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
      throw ServiceError("登录服务返回的加密密钥无效")
    }
    struct Cursor {
      let bytes: [UInt8]
      var offset = 0
      mutating func read(_ tag: UInt8) throws -> [UInt8] {
        guard offset + 2 <= bytes.count, bytes[offset] == tag else { throw ServiceError("登录加密密钥格式无效") }
        offset += 1
        var length = Int(bytes[offset]); offset += 1
        if length & 128 != 0 {
          let count = length & 127
          guard (1...4).contains(count), offset + count <= bytes.count else { throw ServiceError("登录加密密钥格式无效") }
          length = 0
          for _ in 0..<count { length = length * 256 + Int(bytes[offset]); offset += 1 }
        }
        guard length <= bytes.count - offset else { throw ServiceError("登录加密密钥格式无效") }
        let result = Array(bytes[offset..<offset + length]); offset += length
        return result
      }
    }
    var top = Cursor(bytes: Array(der))
    var body = Cursor(bytes: try top.read(0x30))
    guard top.offset == der.count else { throw ServiceError("登录加密密钥格式无效") }
    if body.bytes.first == 0x02 {
      _ = try body.read(0x02); _ = try body.read(0x02)
      guard body.offset == body.bytes.count else { throw ServiceError("登录加密密钥格式无效") }
      return der
    }
    let algorithm = try body.read(0x30)
    // rsaEncryption OID, with or without an explicit NULL parameter.
    guard algorithm.starts(with: [0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]) else {
      throw ServiceError("登录加密密钥类型无效")
    }
    let bitString = try body.read(0x03)
    guard body.offset == body.bytes.count, bitString.first == 0, bitString.count > 1 else {
      throw ServiceError("登录加密密钥格式无效")
    }
    return Data(bitString.dropFirst())
  }
  static func encrypt(_ plaintext: String, pem: String) throws -> String {
    try MobileRSA.encrypt(Data(plaintext.utf8), publicKey: publicKeyDER(pem)).base64EncodedString()
  }
}

enum MobileRSA {
  static func encrypt(_ bytes: Data, publicKey der: Data) throws -> Data {
    let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error),
      SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionPKCS1)
    else { throw ServiceError("无法使用登录加密密钥") }
    guard bytes.count <= SecKeyGetBlockSize(key) - 11 else { throw ServiceError("密码过长") }
    guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, bytes as CFData, &error) else {
      throw ServiceError("密码加密失败")
    }
    return encrypted as Data
  }
}
