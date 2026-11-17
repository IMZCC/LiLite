import Foundation

#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

enum OfflineSealedTrack {
  private static let magic = Data("PILICACH1".utf8), chunk = 1 << 20
  private static func integer(_ i: UInt64) -> Data {
    var b = i.bigEndian
    return withUnsafeBytes(of: &b) { Data($0) }
  }
  private static func exact(_ n: Int, _ h: FileHandle) throws -> Data {
    var d = Data()
    while d.count < n {
      guard let part = try h.read(upToCount: n - d.count), !part.isEmpty else {
        throw ServiceError("账号缓存文件不完整")
      }
      d.append(part)
    }
    return d
  }
  static func seal(_ source: URL, to dest: URL, key: SymmetricKey, context: Data) throws {
    let n = try OfflinePackage.size(source)
    var random = UUID().uuid
    let header = magic + integer(UInt64(n)) + withUnsafeBytes(of: &random) { Data($0) }
    let derived = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: key, salt: header, info: context, outputByteCount: 32)
    try header.write(
      to: dest, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
    let from = try FileHandle(forReadingFrom: source)
    defer { try? from.close() }
    let out = try FileHandle(forWritingTo: dest)
    defer { try? out.close() }
    try out.seekToEnd()
    var remaining = n
    var index: UInt64 = 0
    while remaining > 0 {
      try Task.checkCancellation()
      let count = Int(min(Int64(chunk), remaining))
      let block = try AES.GCM.seal(
        exact(count, from), using: derived, authenticating: header + integer(index))
      guard let blob = block.combined else { throw ServiceError("无法保护账号缓存") }
      try out.write(contentsOf: blob)
      remaining -= Int64(count)
      index += 1
    }
    guard (try from.read(upToCount: 1))?.isEmpty != false else { throw ServiceError("缓存源文件发生变化") }
  }
  /// Nil sink authenticates and hashes a previously published package without opening a plaintext copy.
  static func open(_ source: URL, to dest: URL?, key: SymmetricKey, context: Data) throws -> String
  {
    let from = try FileHandle(forReadingFrom: source)
    defer { try? from.close() }
    let header = try exact(magic.count + 8 + 16, from)
    guard header.starts(with: magic) else { throw ServiceError("不是此账号的缓存文件") }
    let n = header.dropFirst(magic.count).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    let actual = try OfflinePackage.size(source)
    guard n > 0, n <= UInt64(actual) else { throw ServiceError("账号缓存长度无效") }
    let derived = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: key, salt: header, info: context, outputByteCount: 32)
    let sink: FileHandle?
    if let dest {
      try Data().write(
        to: dest,
        options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
      sink = try FileHandle(forWritingTo: dest)
    } else {
      sink = nil
    }
    defer { try? sink?.close() }
    var left = n
    var index: UInt64 = 0
    var digest = SHA256()
    while left > 0 {
      try Task.checkCancellation()
      let count = Int(min(UInt64(chunk), left))
      let data = try exact(count + 28, from)
      let clear = try AES.GCM.open(
        .init(combined: data), using: derived, authenticating: header + integer(index))
      guard clear.count == count else { throw ServiceError("账号缓存校验失败") }
      digest.update(data: clear)
      try sink?.write(contentsOf: clear)
      left -= UInt64(count)
      index += 1
    }
    guard (try from.read(upToCount: 1))?.isEmpty != false else { throw ServiceError("账号缓存尾部无效") }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
