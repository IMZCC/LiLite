import Foundation

/// Reversible public AV/BV archive identifiers (lib/utils/id_utils.dart).
enum ArchiveNumber {
  private static let alphabet = Array(
    "FcwAPNKTMug3GV5Lj7EJnHpWsx4tb8haYeviqBz6rkCy12mUSDQX9RdoZf".utf8)
  private static let mask: Int64 = (1 << 51) - 1, salt: Int64 = 23_442_827_791_579
  static func bv(_ id: Int64) -> String? {
    guard id > 0, id <= mask else { return nil }
    var bytes = Array("BV1000000000".utf8)
    var n = ((mask + 1) | id) ^ salt
    var i = bytes.count - 1
    while n > 0 && i >= 3 {
      bytes[i] = alphabet[Int(n % 58)]
      n /= 58
      i -= 1
    }
    guard n == 0 else { return nil }
    bytes.swapAt(3, 9)
    bytes.swapAt(4, 7)
    return String(decoding: bytes, as: UTF8.self)
  }
  static func av(_ code: String) -> Int64? {
    var bytes = Array(code.utf8)
    guard bytes.count == 12, String(decoding: bytes.prefix(3), as: UTF8.self).uppercased() == "BV1"
    else { return nil }
    bytes.swapAt(3, 9)
    bytes.swapAt(4, 7)
    var n: Int64 = 0
    for ch in bytes[3...] {
      guard let d = alphabet.firstIndex(of: ch) else { return nil }
      n = n * 58 + Int64(d)
    }
    let id = (n & mask) ^ salt
    guard let canonical = bv(id), canonical.dropFirst(3) == code.dropFirst(3) else { return nil }
    return id
  }
}
