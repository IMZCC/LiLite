import Foundation

struct MediaRange {
  let total: Int64, length: Int64
  private(set) var received: Int64 = 0

  init?(field: String?, request: String?, declared: Int64) {
    guard let field, field.lowercased().hasPrefix("bytes "), let request else { return nil }
    let sides = field.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
    guard sides.count == 2, sides[1].utf8.allSatisfy({ (48...57).contains($0) }),
      let n = Int64(sides[1]), let wanted = RelayRange(request, length: n)
    else { return nil }
    let ends = sides[0].split(separator: "-", omittingEmptySubsequences: false)
    guard ends.count == 2, ends.allSatisfy({ $0.utf8.allSatisfy({ (48...57).contains($0) }) }),
      Int64(ends[0]) == wanted.first, Int64(ends[1]) == wanted.last
    else { return nil }
    total = n
    length = wanted.last - wanted.first + 1
    guard declared == -1 || declared == length else { return nil }
  }

  mutating func accept(_ count: Int) -> Bool {
    guard count >= 0, Int64(count) <= length - received else { return false }
    received += Int64(count)
    return true
  }
  var complete: Bool { received == length }
}
