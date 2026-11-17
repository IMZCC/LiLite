struct RelayRange {
  let first: Int64, last: Int64
  init?(_ field: String?, length: Int64) {
    guard length > 0, length < Int64.max else { return nil }
    guard let field else {
      first = 0
      last = length - 1
      return
    }
    guard field.hasPrefix("bytes=") else { return nil }
    let bits = field.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
    guard bits.count == 2, bits.allSatisfy({ $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }) else {
      return nil
    }
    if bits[0].isEmpty {
      guard let n = Int64(bits[1]), n > 0 else { return nil }
      first = max(0, length - n)
      last = length - 1
    } else {
      guard let f = Int64(bits[0]), f < length else { return nil }
      first = f
      if bits[1].isEmpty {
        last = length - 1
      } else {
        guard let end = Int64(bits[1]), end >= f else { return nil }
        last = min(end, length - 1)
      }
    }
  }
}
